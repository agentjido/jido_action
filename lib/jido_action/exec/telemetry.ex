defmodule Jido.Exec.Telemetry do
  @moduledoc """
  Centralized telemetry, logging, and debugging helpers for Jido.Exec.

  This module consolidates all telemetry event emission, logging functionality,
  and error message extraction used throughout the execution system.
  """

  alias Jido.Action.Error
  alias Jido.Action.Sanitizer
  alias Jido.Action.Util
  require Logger

  @inspect_opts [charlists: :as_lists, printable_limit: :infinity, limit: :infinity]

  @doc """
  Emits telemetry start event for action execution.
  """
  @spec emit_start_event(module(), map(), map()) :: :ok
  def emit_start_event(action, params, context) do
    :telemetry.execute(
      [:jido, :action, :start],
      %{system_time: System.system_time()},
      span_start_metadata(action, params, context, context)
    )
  end

  @doc """
  Emits telemetry end event for action execution.
  """
  @spec emit_end_event(module(), map(), map(), any()) :: :ok
  def emit_end_event(action, params, context, result) do
    measurements = %{
      system_time: System.system_time(),
      # Duration would need to be calculated by caller
      duration: 0
    }

    metadata =
      span_stop_metadata(action, params, context, result, context)

    :telemetry.execute([:jido, :action, :stop], measurements, metadata)
  end

  @doc false
  @spec span_start_metadata(module(), map(), map(), keyword() | map()) :: map()
  def span_start_metadata(action, params, context, opts_or_context) do
    %{
      action: action,
      params: params,
      context: context
    }
    |> maybe_put(:jido, extract_jido(opts_or_context))
  end

  @doc false
  @spec span_stop_metadata(any()) :: map()
  def span_stop_metadata(result) do
    %{result: result}
    |> Map.merge(stop_outcome_metadata(result))
  end

  @doc false
  @spec span_stop_metadata(module(), map(), map(), any(), keyword() | map()) :: map()
  def span_stop_metadata(action, params, context, result, opts_or_context) do
    span_start_metadata(action, params, context, opts_or_context)
    |> Map.merge(span_stop_metadata(result))
  end

  defp stop_outcome_metadata({:ok, _result}), do: %{outcome: :ok}

  defp stop_outcome_metadata({:ok, _result, _directive}) do
    %{outcome: :ok, directive?: true}
  end

  defp stop_outcome_metadata({:error, error}) do
    normalized = Error.to_map(error)

    %{
      outcome: :error,
      error_type: normalized.type,
      retryable?: normalized.retryable?
    }
  end

  defp stop_outcome_metadata({:error, error, _directive}) do
    stop_outcome_metadata({:error, error})
    |> Map.put(:directive?, true)
  end

  defp stop_outcome_metadata(_result), do: %{outcome: :unknown}

  @doc """
  Logs the start of action execution.
  """
  @spec log_execution_start(module(), map(), map()) :: :ok
  def log_execution_start(action, params, context) do
    Logger.debug(fn ->
      "Starting execution of #{inspect(action)}, params: #{safe_inspect(params)}, context: #{safe_inspect(context)}"
    end)
  end

  @doc """
  Logs the end of action execution.
  """
  @spec log_execution_end(module(), map(), map(), any()) :: :ok
  def log_execution_end(action, _params, _context, result) do
    case result do
      {:ok, result_data} ->
        Logger.debug(fn ->
          "Finished execution of #{inspect(action)}, result: #{safe_inspect(result_data)}"
        end)

      {:ok, result_data, directive} ->
        Logger.debug(fn ->
          "Finished execution of #{inspect(action)}, result: #{safe_inspect(result_data)}, directive: #{safe_inspect(directive)}"
        end)

      {:error, error} ->
        Logger.error(fn -> "Action #{inspect(action)} failed: #{safe_inspect(error)}" end)

      {:error, error, directive} ->
        Logger.error(fn ->
          "Action #{inspect(action)} failed: #{safe_inspect(error)}, directive: #{safe_inspect(directive)}"
        end)

      other ->
        Logger.debug(fn ->
          "Finished execution of #{inspect(action)}, result: #{safe_inspect(other)}"
        end)
    end
  end

  @doc """
  Safely extracts error messages from various error types, handling nil and nested cases.
  """
  @spec extract_safe_error_message(any()) :: String.t()
  def extract_safe_error_message(error) do
    case error do
      %{message: %{message: inner_message}} when is_binary(inner_message) ->
        inner_message

      %{message: nil} ->
        ""

      %{message: message} when is_binary(message) ->
        message

      %{message: message} when is_struct(message) ->
        if Map.has_key?(message, :message) and is_binary(message.message) do
          message.message
        else
          safe_inspect(message)
        end

      _ ->
        safe_inspect(error)
    end
  end

  @doc """
  Conditional logging wrapper for start events.
  """
  @spec cond_log_start(atom(), module(), map(), map()) :: :ok
  def cond_log_start(log_level, action, params, context) do
    Util.cond_log(
      log_level,
      :debug,
      fn ->
        "Starting execution of #{inspect(action)}, params: #{safe_inspect(params)}, context: #{safe_inspect(context)}"
      end
    )
  end

  @doc """
  Conditional logging wrapper for end events.
  """
  @spec cond_log_end(atom(), module(), any()) :: :ok
  def cond_log_end(log_level, action, result) do
    case result do
      {:ok, result_data} ->
        Util.cond_log(
          log_level,
          :debug,
          fn ->
            "Finished execution of #{inspect(action)}, result: #{safe_inspect(result_data)}"
          end
        )

      {:ok, result_data, directive} ->
        Util.cond_log(
          log_level,
          :debug,
          fn ->
            "Finished execution of #{inspect(action)}, result: #{safe_inspect(result_data)}, directive: #{safe_inspect(directive)}"
          end
        )

      {:error, error} ->
        Util.cond_log(log_level, :error, fn ->
          "Action #{inspect(action)} failed: #{safe_inspect(error)}"
        end)

      {:error, error, directive} ->
        Util.cond_log(
          log_level,
          :error,
          fn ->
            "Action #{inspect(action)} failed: #{safe_inspect(error)}, directive: #{safe_inspect(directive)}"
          end
        )

      other ->
        Util.cond_log(
          log_level,
          :debug,
          fn ->
            "Finished execution of #{inspect(action)}, result: #{safe_inspect(other)}"
          end
        )
    end
  end

  @doc """
  Conditional logging wrapper for errors.
  """
  @spec cond_log_error(atom(), module(), any()) :: :ok
  def cond_log_error(log_level, action, error) do
    Util.cond_log(log_level, :error, fn ->
      "Action #{inspect(action)} failed: #{safe_inspect(error)}"
    end)
  end

  @doc """
  Conditional logging wrapper for retry attempts.
  """
  @spec cond_log_retry(atom(), module(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :ok
  def cond_log_retry(log_level, action, retry_count, max_retries, backoff) do
    Util.cond_log(
      log_level,
      :info,
      fn ->
        "Retrying #{inspect(action)} (attempt #{retry_count + 1}/#{max_retries}) after #{backoff}ms backoff"
      end
    )
  end

  @doc """
  Conditional logging wrapper for general messages.
  """
  @spec cond_log_message(atom(), atom(), String.t()) :: :ok
  def cond_log_message(log_level, level, message) do
    Util.cond_log(log_level, level, message)
  end

  @doc """
  Conditional logging wrapper for function errors.
  """
  @spec cond_log_function_error(atom(), any()) :: :ok
  def cond_log_function_error(log_level, error) do
    Util.cond_log(
      log_level,
      :warning,
      fn ->
        "Function invocation error in action: #{extract_safe_error_message(error)}"
      end
    )
  end

  @doc """
  Conditional logging wrapper for unexpected errors.
  """
  @spec cond_log_unexpected_error(atom(), any()) :: :ok
  def cond_log_unexpected_error(log_level, error) do
    Util.cond_log(
      log_level,
      :error,
      fn -> "Unexpected error in action: #{extract_safe_error_message(error)}" end
    )
  end

  @doc """
  Conditional logging wrapper for caught errors.
  """
  @spec cond_log_caught_error(atom(), any()) :: :ok
  def cond_log_caught_error(log_level, reason) do
    Util.cond_log(
      log_level,
      :warning,
      fn ->
        "Caught unexpected throw/exit in action: #{extract_safe_error_message(reason)}"
      end
    )
  end

  @doc """
  Conditional logging wrapper for execution debug.
  """
  @spec cond_log_execution_debug(atom(), module(), map(), map()) :: :ok
  def cond_log_execution_debug(log_level, action, params, context) do
    cond_log_start(log_level, action, params, context)
  end

  @doc """
  Conditional logging wrapper for validation failures.
  """
  @spec cond_log_validation_failure(atom(), module(), any()) :: :ok
  def cond_log_validation_failure(log_level, action, validation_error) do
    Util.cond_log(
      log_level,
      :error,
      fn ->
        "Action #{inspect(action)} output validation failed: #{safe_inspect(validation_error)}"
      end
    )
  end

  @doc """
  Conditional logging wrapper for general failures.
  """
  @spec cond_log_failure(atom(), any()) :: :ok
  def cond_log_failure(log_level, reason) do
    Util.cond_log(log_level, :error, fn ->
      "Action execution failed: #{safe_inspect(reason)}"
    end)
  end

  @doc false
  @spec sanitize_value(any()) :: any()
  def sanitize_value(value), do: Sanitizer.sanitize_telemetry(value)

  defp safe_inspect(value) do
    inspect(sanitize_value(value), @inspect_opts)
  rescue
    _ ->
      fallback_safe_inspect(value)
  end

  defp fallback_safe_inspect(value) do
    inspect(Sanitizer.sanitize(value), @inspect_opts)
  rescue
    _ -> "[uninspectable value]"
  end

  defp extract_jido(opts_or_context) when is_list(opts_or_context),
    do: Keyword.get(opts_or_context, :jido)

  defp extract_jido(opts_or_context) when is_map(opts_or_context),
    do: Map.get(opts_or_context, :jido) || Map.get(opts_or_context, "jido")

  defp extract_jido(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
