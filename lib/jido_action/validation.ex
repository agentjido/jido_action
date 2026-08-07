defmodule Jido.Action.Validation do
  @moduledoc false

  alias Jido.Action.Error

  @doc false
  @spec open_validate(term(), term(), map()) ::
          {:ok, term()} | {:error, Error.InvalidInputError.t()}
  def open_validate([], data, _details), do: {:ok, data}

  def open_validate(schema, data, details) when is_map(details) do
    if zoi_schema?(schema) do
      schema
      |> parse_schema(data)
      |> handle_validation_result(schema, details)
    else
      {:error, Error.validation_error("Unsupported schema type", details)}
    end
  end

  @doc false
  @spec zoi_schema?(term()) :: boolean()
  def zoi_schema?(value), do: is_struct(value) && Zoi.Type.impl_for(value) != nil

  defp parse_schema(%Zoi.Types.Map{fields: fields} = schema, data)
       when is_list(fields) and is_map(data) do
    {Zoi.parse(%{schema | unrecognized_keys: :preserve}, data), %{}}
  end

  defp parse_schema(%Zoi.Types.Struct{module: module} = schema, data)
       when is_struct(data, module) do
    {Zoi.parse(schema, data), %{}}
  end

  defp parse_schema(%Zoi.Types.Struct{fields: fields, coerce: true} = schema, data)
       when is_list(fields) and is_map(data) do
    open_schema = %Zoi.Types.Map{
      fields: fields,
      unrecognized_keys: :preserve,
      coerce: true,
      empty_values: schema.empty_values,
      meta: schema.meta
    }

    {Zoi.parse(open_schema, data), %{}}
  end

  defp parse_schema(schema, data), do: {Zoi.parse(schema, data), %{}}

  defp handle_validation_result({{:ok, validated}, unknown}, schema, _details) do
    validated = if is_struct(validated), do: Map.from_struct(validated), else: validated

    if is_map(validated) and object_schema?(schema) do
      {:ok, Map.merge(unknown, validated)}
    else
      {:ok, validated}
    end
  end

  defp handle_validation_result({{:error, errors}, _unknown}, _schema, details) do
    {:error,
     Error.validation_error(
       Zoi.prettify_errors(errors),
       Map.put(details, :errors, Enum.map(errors, &format_zoi_error/1))
     )}
  end

  defp object_schema?(%{__struct__: Zoi.Types.Map}), do: true
  defp object_schema?(%{__struct__: Zoi.Types.Struct}), do: true
  defp object_schema?(_schema), do: false

  defp format_zoi_error(%{path: path, message: message} = error) do
    %{
      path: path,
      message: message,
      code: Map.get(error, :code)
    }
  end
end
