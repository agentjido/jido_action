defmodule Jido.Action.Runtime do
  @moduledoc """
  Runtime validation helpers used by generated `Jido.Action` modules.

  This module validates action parameters and output while preserving unknown keys.
  """

  alias Jido.Action.Schema

  @doc """
  Validates action input parameters.
  """
  @spec validate_params(map(), module()) :: {:ok, map()} | {:error, any()}
  def validate_params(params, module) do
    do_validate_params(params, module)
  end

  @doc """
  Validates action output.
  """
  @spec validate_output(map(), module()) :: {:ok, map()} | {:error, any()}
  def validate_output(output, module) do
    do_validate_output(output, module)
  end

  defp do_validate_params(params, module) do
    param_schema = module.schema()
    {known_params, unknown_params} = split_known_and_unknown(params, param_schema)

    param_schema
    |> Schema.validate(known_params)
    |> handle_validation_result(unknown_params, "Action", module)
  end

  defp do_validate_output(output, module) do
    out_schema = module.output_schema()
    {known_output, unknown_output} = split_known_and_unknown(output, out_schema)

    out_schema
    |> Schema.validate(known_output)
    |> handle_validation_result(unknown_output, "Action output", module)
  end

  defp handle_validation_result({:ok, validated}, unknown, _error_context, _module) do
    validated_map = struct_to_map(validated)
    {:ok, Map.merge(unknown, validated_map)}
  end

  defp handle_validation_result({:error, error}, _unknown, error_context, module) do
    error
    |> Schema.format_error(error_context, module)
    |> then(&{:error, &1})
  end

  defp split_known_and_unknown(data, schema) do
    known_keys = Schema.known_keys(schema)
    Map.split(data, known_keys)
  end

  defp struct_to_map(value) when is_struct(value), do: Map.from_struct(value)
  defp struct_to_map(value), do: value
end
