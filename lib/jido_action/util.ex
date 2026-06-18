defmodule Jido.Action.Util do
  @moduledoc """
  Utility functions for Jido.Action.
  """

  require Logger

  @default_log_level :info
  @max_action_name_bytes 256

  @doc """
  Conditionally logs a message based on comparing threshold and message log levels.

  This function provides a way to conditionally log messages by comparing a threshold level
  against the message's intended log level. The message will only be logged if the threshold
  level is less than or equal to the message level.

  ## Parameters

  - `threshold_level`: The minimum log level threshold (e.g. :debug, :info, etc)
  - `message_level`: The log level for this specific message
  - `message`: The message to potentially log
  - `opts`: Additional options passed to Logger.log/3

  ## Returns

  - `:ok` in all cases

  ## Examples

      # Will log since :info >= :info
      iex> cond_log(:info, :info, "test message")
      :ok

      # Won't log since :info > :debug
      iex> cond_log(:info, :debug, "test message")
      :ok

      # Will log since :debug <= :info
      iex> cond_log(:debug, :info, "test message")
      :ok
  """
  @spec cond_log(Logger.level(), Logger.level(), Logger.message(), keyword()) :: :ok
  def cond_log(threshold_level, message_level, message, opts \\ []) do
    valid_levels = Logger.levels()

    cond do
      threshold_level not in valid_levels or message_level not in valid_levels ->
        # Don't log
        :ok

      Logger.compare_levels(threshold_level, message_level) in [:lt, :eq] ->
        Logger.log(message_level, message, opts)

      true ->
        :ok
    end
  end

  @doc """
  Returns the default execution log threshold for Jido.

  This reads `:jido_action, :default_log_level` and falls back to `:info`
  when the config value is missing or invalid.
  """
  @spec default_log_level() :: Logger.level()
  def default_log_level do
    case Application.get_env(:jido_action, :default_log_level, @default_log_level) do
      level ->
        if level in Logger.levels() do
          level
        else
          Logger.warning(fn ->
            "Invalid :jido_action config for :default_log_level: #{inspect(level)}. " <>
              "Expected one of #{inspect(Logger.levels())}; using fallback #{inspect(@default_log_level)}."
          end)

          @default_log_level
        end
    end
  end

  @doc """
  Resolves the execution log threshold for a call.

  Precedence:

  1. `opts[:log_level]`
  2. `config :jido_action, default_log_level: ...`
  3. built-in `:info`
  """
  @spec resolve_log_level(keyword()) :: Logger.level()
  def resolve_log_level(opts \\ []) do
    case Keyword.fetch(opts, :log_level) do
      {:ok, level} ->
        if level in Logger.levels() do
          level
        else
          fallback = default_log_level()

          Logger.warning(fn ->
            "Invalid execution :log_level option: #{inspect(level)}. " <>
              "Expected one of #{inspect(Logger.levels())}; using #{inspect(fallback)}."
          end)

          fallback
        end

      :error ->
        default_log_level()
    end
  end

  @doc """
  Validates the metadata name of an Action.

  Action names are compile-time string metadata. They must be non-blank and
  bounded, but they are not required to be slugs or Elixir identifiers.

  ## Parameters

  - `name`: The name to validate.

  ## Returns

  - `:ok` if the name is valid.
  - `{:error, reason}` if the name is invalid.

  ## Examples

      iex> Jido.Action.Util.validate_name("billing.charge-card")
      :ok

      iex> Jido.Action.Util.validate_name(" ")
      {:error, "Action name cannot be blank."}

  """
  @spec validate_name(any(), keyword()) :: :ok | {:error, String.t()}
  def validate_name(name, _opts \\ [])

  def validate_name(name, _opts) when is_binary(name) do
    cond do
      String.trim(name) == "" ->
        {:error, "Action name cannot be blank."}

      byte_size(name) > @max_action_name_bytes ->
        {:error, "Action name cannot exceed #{@max_action_name_bytes} bytes."}

      true ->
        :ok
    end
  end

  def validate_name(_name, _opts) do
    {:error, "Action name must be a string."}
  end

  @doc """
  Normalizes nested result tuples to single-level tuples.

  This function handles cases where callbacks or functions return nested tuples
  like {:ok, {:ok, value}} or {:error, {:error, reason}}, flattening them to
  proper single-level result tuples.

  ## Examples

      iex> normalize_result({:ok, {:ok, "value"}})
      {:ok, "value"}
      
      iex> normalize_result({:ok, {:error, "reason"}})
      {:error, "reason"}
      
      iex> normalize_result({:ok, "value"})
      {:ok, "value"}
      
      iex> normalize_result("value")
      {:ok, "value"}
  """
  @spec normalize_result(any()) :: {:ok, any()} | {:error, any()}
  def normalize_result({:ok, {:ok, value}}), do: {:ok, value}
  def normalize_result({:ok, {:error, reason}}), do: {:error, reason}
  def normalize_result({:error, {:ok, _value}}), do: {:error, "Invalid nested error tuple"}
  def normalize_result({:error, {:error, reason}}), do: {:error, reason}
  def normalize_result({:ok, value}), do: {:ok, value}
  def normalize_result({:error, reason}), do: {:error, reason}
  def normalize_result(value), do: {:ok, value}

  @doc """
  Wraps value in success tuple if not already a result tuple.

  ## Examples

      iex> wrap_ok({:ok, "value"})
      {:ok, "value"}
      
      iex> wrap_ok({:error, "reason"})
      {:error, "reason"}
      
      iex> wrap_ok("value")
      {:ok, "value"}
  """
  @spec wrap_ok(any()) :: {:ok, any()} | {:error, any()}
  def wrap_ok({:ok, _} = result), do: result
  def wrap_ok({:error, _} = result), do: result
  def wrap_ok(value), do: {:ok, value}

  @doc """
  Wraps value in error tuple.

  ## Examples

      iex> wrap_error({:error, "reason"})
      {:error, "reason"}
      
      iex> wrap_error("reason")
      {:error, "reason"}
  """
  @spec wrap_error(any()) :: {:error, any()}
  def wrap_error({:error, _} = error), do: error
  def wrap_error(reason), do: {:error, reason}
end
