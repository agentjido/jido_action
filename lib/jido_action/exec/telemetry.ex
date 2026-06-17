defmodule Jido.Exec.Telemetry do
  @moduledoc """
  Centralized telemetry, logging, and debugging helpers for Jido.Exec.

  This module consolidates all telemetry event emission, logging functionality,
  and error message extraction used throughout the execution system.
  """

  alias Jido.Action.Error
  alias Jido.Action.Util
  require Logger

  @inspect_opts [charlists: :as_lists, printable_limit: :infinity, limit: :infinity]
  @redacted_value "[REDACTED]"
  @max_depth 4
  @max_collection_items 25
  @max_binary_bytes 256
  @sensitive_assignment_key_pattern "password|passwd|passphrase|secret|token|api[_-]?key|apikey|access[_-]?key|accesskey|private[_-]?key|privatekey|authorization|auth|cookie|session|credential"
  @sensitive_assignment_regex ~r/((?:"|')?(?:#{@sensitive_assignment_key_pattern})(?:"|')?\s*(?:=>|=|:)\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)/i
  @authorization_token_regex ~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i
  @sensitive_patterns [
    "password",
    "passwd",
    "passphrase",
    "secret",
    "token",
    "apikey",
    "accesskey",
    "privatekey",
    "authorization",
    "auth",
    "cookie",
    "session",
    "credential"
  ]

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
  def span_start_metadata(action, _params, _context, opts_or_context) do
    %{
      action: action
    }
    |> maybe_put(:jido, extract_jido(opts_or_context))
  end

  @doc false
  @spec span_stop_metadata(any()) :: map()
  def span_stop_metadata(result) do
    stop_outcome_metadata(result)
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
        safe_message(inner_message)

      %{message: nil} ->
        ""

      %{message: message} when is_binary(message) ->
        safe_message(message)

      %{message: message} when is_struct(message) ->
        safe_inspect(message)

      _ ->
        safe_inspect(error)
    end
  end

  defp safe_message(message) when is_binary(message), do: sanitize_value(message)

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
  def sanitize_value(value), do: do_sanitize_telemetry(value, 0, telemetry_opts())

  defp safe_inspect(value) do
    inspect(sanitize_value(value), @inspect_opts)
  rescue
    _ ->
      fallback_safe_inspect(value)
  end

  defp fallback_safe_inspect(value) when is_binary(value) do
    value
    |> redact_sensitive_binary()
    |> truncate_binary(telemetry_opts())
  end

  defp fallback_safe_inspect(value), do: fallback_raw_inspect(value)

  defp telemetry_opts do
    %{
      redacted_value: @redacted_value,
      max_depth: @max_depth,
      max_collection_items: @max_collection_items,
      max_binary_bytes: @max_binary_bytes,
      sensitive_patterns: @sensitive_patterns
    }
  end

  defp do_sanitize_telemetry(value, depth, opts) when depth >= opts.max_depth do
    summarize_truncated(value, opts)
  end

  defp do_sanitize_telemetry(%_{} = struct, depth, opts) when depth + 1 >= opts.max_depth do
    summarize_truncated_struct(struct, opts)
  end

  defp do_sanitize_telemetry(%_{} = struct, depth, opts) do
    struct
    |> Map.from_struct()
    |> do_sanitize_telemetry(depth, opts)
    |> Map.put(:__struct__, normalize_struct_marker(struct.__struct__))
  end

  defp do_sanitize_telemetry(value, depth, opts) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.map(fn {key, raw_value} ->
      {sanitize_telemetry_key(key, depth + 1, opts), key, raw_value}
    end)
    |> Enum.sort_by(fn {sanitized_key, _key, _value} -> raw_safe_inspect(sanitized_key) end)
    |> Enum.split(opts.max_collection_items)
    |> then(fn {kept, dropped} ->
      sanitized =
        kept
        |> Enum.map(fn {sanitized_key, key, raw_value} ->
          sanitized_value =
            if sensitive_key?(key, opts) do
              opts.redacted_value
            else
              do_sanitize_telemetry(raw_value, depth + 1, opts)
            end

          {sanitized_key, sanitized_value}
        end)
        |> Map.new()

      if dropped == [] do
        sanitized
      else
        Map.put(sanitized, :__truncated_fields__, length(dropped))
      end
    end)
  end

  defp do_sanitize_telemetry(value, depth, opts) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        {kept, dropped} = Enum.split(items, opts.max_collection_items)
        sanitized = Enum.map(kept, &do_sanitize_telemetry(&1, depth + 1, opts))

        if dropped == [] do
          sanitized
        else
          sanitized ++ [%{__truncated_items__: length(dropped)}]
        end

      {:improper, items, tail} ->
        {kept, dropped} = Enum.split(items, opts.max_collection_items)

        improper =
          %{
            __type__: :improper_list,
            items: Enum.map(kept, &do_sanitize_telemetry(&1, depth + 1, opts)),
            tail: do_sanitize_telemetry(tail, depth + 1, opts)
          }

        if dropped == [] do
          improper
        else
          Map.put(improper, :__truncated_items__, length(dropped))
        end
    end
  end

  defp do_sanitize_telemetry(value, depth, opts) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> do_sanitize_telemetry(depth, opts)
    |> List.to_tuple()
  end

  defp do_sanitize_telemetry(value, _depth, opts) when is_binary(value) do
    value
    |> redact_sensitive_binary()
    |> truncate_binary(opts)
  end

  defp do_sanitize_telemetry(value, _depth, _opts), do: value

  defp sensitive_key?(key, opts) when is_atom(key), do: sensitive_key?(Atom.to_string(key), opts)

  defp sensitive_key?(key, opts) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/u, "")
    Enum.any?(opts.sensitive_patterns, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(key, opts), do: sensitive_key?(raw_safe_inspect(key), opts)

  defp sanitize_telemetry_key(key, _depth, _opts)
       when is_atom(key) or is_binary(key) or is_number(key) or is_boolean(key) or is_nil(key),
       do: key

  defp sanitize_telemetry_key(key, depth, opts), do: do_sanitize_telemetry(key, depth, opts)

  defp redact_sensitive_binary(value) do
    value
    |> then(&Regex.replace(@sensitive_assignment_regex, &1, "\\1[REDACTED]"))
    |> then(&Regex.replace(@authorization_token_regex, &1, "\\1 [REDACTED]"))
  end

  defp truncate_binary(value, opts) do
    if byte_size(value) > opts.max_binary_bytes do
      kept = binary_part(value, 0, opts.max_binary_bytes)
      truncated = byte_size(value) - opts.max_binary_bytes
      "#{kept}...(truncated #{truncated} bytes)"
    else
      value
    end
  end

  defp summarize_truncated(%_{} = struct, opts), do: summarize_truncated_struct(struct, opts)

  defp summarize_truncated(value, opts) when is_map(value) do
    %{__truncated_depth__: opts.max_depth, type: :map, size: map_size(value)}
  end

  defp summarize_truncated(value, opts) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        %{__truncated_depth__: opts.max_depth, type: :list, size: length(items)}

      {:improper, items, tail} ->
        %{
          __truncated_depth__: opts.max_depth,
          type: :improper_list,
          size: length(items),
          tail: raw_safe_inspect(tail)
        }
    end
  end

  defp summarize_truncated(value, opts) when is_tuple(value) do
    %{__truncated_depth__: opts.max_depth, type: :tuple, size: tuple_size(value)}
  end

  defp summarize_truncated(value, opts) when is_binary(value) do
    do_sanitize_telemetry(value, opts.max_depth - 1, opts)
  end

  defp summarize_truncated(value, _opts), do: value

  defp summarize_truncated_struct(struct, opts) do
    %{
      __truncated_depth__: opts.max_depth,
      type: :struct,
      module: normalize_struct_marker(struct.__struct__),
      size: map_size(struct)
    }
  end

  defp normalize_struct_marker(mod) when is_atom(mod), do: inspect(mod)

  defp raw_safe_inspect(value) do
    inspect(value, @inspect_opts)
  rescue
    _ -> fallback_raw_inspect(value)
  end

  defp fallback_raw_inspect(value) when is_function(value), do: "#Function<uninspectable>"

  defp fallback_raw_inspect(value) when is_pid(value),
    do: List.to_string(:erlang.pid_to_list(value))

  defp fallback_raw_inspect(value) when is_reference(value),
    do: List.to_string(:erlang.ref_to_list(value))

  defp fallback_raw_inspect(value) when is_port(value),
    do: List.to_string(:erlang.port_to_list(value))

  defp fallback_raw_inspect(%_{} = struct) do
    "#Struct<#{normalize_struct_marker(struct.__struct__)}>"
  end

  defp fallback_raw_inspect(value) when is_map(value), do: "#Map<size=#{map_size(value)}>"

  defp fallback_raw_inspect(value) when is_list(value) do
    case list_parts(value) do
      {:proper, items} ->
        "#List<size=#{length(items)}>"

      {:improper, items, tail} ->
        "#ImproperList<size=#{length(items)}, tail=#{raw_safe_inspect(tail)}>"
    end
  end

  defp fallback_raw_inspect(value) when is_tuple(value), do: "#Tuple<size=#{tuple_size(value)}>"
  defp fallback_raw_inspect(value) when is_binary(value), do: value
  defp fallback_raw_inspect(value) when is_atom(value), do: Atom.to_string(value)
  defp fallback_raw_inspect(value) when is_number(value), do: to_string(value)
  defp fallback_raw_inspect(value) when is_boolean(value), do: to_string(value)
  defp fallback_raw_inspect(nil), do: "nil"
  defp fallback_raw_inspect(_value), do: "#Term<uninspectable>"

  defp list_parts(list), do: do_list_parts(list, [])

  defp do_list_parts([], acc), do: {:proper, Enum.reverse(acc)}
  defp do_list_parts([head | tail], acc), do: do_list_parts(tail, [head | acc])
  defp do_list_parts(tail, acc), do: {:improper, Enum.reverse(acc), tail}

  defp extract_jido(opts_or_context) when is_list(opts_or_context),
    do: Keyword.get(opts_or_context, :jido)

  defp extract_jido(opts_or_context) when is_map(opts_or_context),
    do: Map.get(opts_or_context, :jido) || Map.get(opts_or_context, "jido")

  defp extract_jido(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
