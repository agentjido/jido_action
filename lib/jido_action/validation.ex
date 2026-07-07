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

  defp parse_schema(schema, data) do
    if is_map(data) and object_schema?(schema) do
      {known_data, unknown_data} = Map.split(data, schema_keys(schema))
      {Zoi.parse(schema, known_data), unknown_data}
    else
      {Zoi.parse(schema, data), %{}}
    end
  end

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

  defp schema_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp schema_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp schema_keys(_schema), do: []

  defp format_zoi_error(%{path: path, message: message} = error) do
    %{
      path: path,
      message: message,
      code: Map.get(error, :code)
    }
  end
end
