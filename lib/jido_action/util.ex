defmodule Jido.Action.Util do
  @moduledoc """
  Utility functions for Jido.Action.
  """

  require Logger
  require OK

  @name_regex ~r/^[a-zA-Z][a-zA-Z0-9_]*$/

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
  Validates the name of a Action.

  The name must contain only letters, numbers, and underscores.

  ## Parameters

  - `name`: The name to validate.

  ## Returns

  - `{:ok, name}` if the name is valid.
  - `{:error, reason}` if the name is invalid.

  ## Examples

      iex> Jido.Action.validate_name("valid_name_123")
      {:ok, "valid_name_123"}

      iex> Jido.Action.validate_name("invalid-name")
      {:error, "The name must contain only letters, numbers, and underscores."}

  """
  @spec validate_name(any()) :: {:ok, String.t()} | {:error, Jido.Action.Error.t()}
  def validate_name(name) when is_binary(name) do
    if Regex.match?(@name_regex, name) do
      OK.success(name)
    else
      "The name must start with a letter and contain only letters, numbers, and underscores."
      |> OK.failure()
    end
  end

  def validate_name(_) do
    "Invalid name format."
    |> OK.failure()
  end
end
