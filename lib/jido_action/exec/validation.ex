defmodule Jido.Exec.Validation do
  @moduledoc """
  Validation functions for Jido.Exec.

  This module handles:
  - Parameter and context normalization
  - Action validation  
  - Parameter validation
  - Output validation
  """

  alias Jido.Action.Error

  require OK

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer()]

  @spec normalize_params(params()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_params(%Error{} = error), do: OK.failure(error)
  def normalize_params(params) when is_map(params), do: OK.success(params)
  def normalize_params(params) when is_list(params), do: OK.success(Map.new(params))
  def normalize_params({:ok, params}) when is_map(params), do: OK.success(params)
  def normalize_params({:ok, params}) when is_list(params), do: OK.success(Map.new(params))
  def normalize_params({:error, reason}), do: OK.failure(Error.validation_error(reason))

  def normalize_params(params),
    do: OK.failure(Error.validation_error("Invalid params type: #{inspect(params)}"))

  @spec normalize_context(context()) :: {:ok, map()} | {:error, Error.t()}
  def normalize_context(context) when is_map(context), do: OK.success(context)
  def normalize_context(context) when is_list(context), do: OK.success(Map.new(context))

  def normalize_context(context),
    do: OK.failure(Error.validation_error("Invalid context type: #{inspect(context)}"))

  @spec validate_action(action()) :: :ok | {:error, Error.t()}
  def validate_action(action) do
    case Code.ensure_compiled(action) do
      {:module, _} ->
        if function_exported?(action, :run, 2) do
          :ok
        else
          {:error,
           Error.invalid_action(
             "Module #{inspect(action)} is not a valid action: missing run/2 function"
           )}
        end

      {:error, reason} ->
        {:error,
         Error.invalid_action("Failed to compile module #{inspect(action)}: #{inspect(reason)}")}
    end
  end

  @spec validate_params(action(), map()) :: {:ok, map()} | {:error, Error.t()}
  def validate_params(action, params) do
    if function_exported?(action, :validate_params, 1) do
      case action.validate_params(params) do
        {:ok, params} ->
          OK.success(params)

        {:error, reason} ->
          OK.failure(reason)

        _ ->
          OK.failure(Error.validation_error("Invalid return from action.validate_params/1"))
      end
    else
      OK.failure(
        Error.invalid_action(
          "Module #{inspect(action)} is not a valid action: missing validate_params/1 function"
        )
      )
    end
  end

  @spec validate_output(action(), map(), run_opts()) :: {:ok, map()} | {:error, Error.t()}
  def validate_output(action, output, opts) do
    log_level = Keyword.get(opts, :log_level, :info)

    if function_exported?(action, :validate_output, 1) do
      case action.validate_output(output) do
        {:ok, validated_output} ->
          Jido.Action.Util.cond_log(
            log_level,
            :debug,
            "Output validation succeeded for #{inspect(action)}"
          )

          OK.success(validated_output)

        {:error, reason} ->
          Jido.Action.Util.cond_log(
            log_level,
            :debug,
            "Output validation failed for #{inspect(action)}: #{inspect(reason)}"
          )

          OK.failure(reason)

        _ ->
          Jido.Action.Util.cond_log(
            log_level,
            :debug,
            "Invalid return from action.validate_output/1"
          )

          OK.failure(Error.validation_error("Invalid return from action.validate_output/1"))
      end
    else
      # If action doesn't have validate_output/1, skip output validation
      Jido.Action.Util.cond_log(
        log_level,
        :debug,
        "No output validation function found for #{inspect(action)}, skipping"
      )

      OK.success(output)
    end
  end
end
