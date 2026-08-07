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

  @doc false
  @spec action_schema?(term()) :: boolean()
  def action_schema?(%Zoi.Types.Map{}), do: true
  def action_schema?(%Zoi.Types.Struct{}), do: true
  def action_schema?(%Zoi.Types.Any{}), do: true
  def action_schema?(%Zoi.Types.DiscriminatedUnion{}), do: true
  def action_schema?(%Zoi.Types.Lazy{}), do: true
  def action_schema?(%Zoi.Types.Literal{value: value}), do: is_map(value)
  def action_schema?(%Zoi.Types.Default{inner: inner}), do: action_schema?(inner)

  def action_schema?(%Zoi.Types.Union{schemas: schemas}),
    do: Enum.any?(schemas, &action_schema?/1)

  def action_schema?(%Zoi.Types.Intersection{schemas: schemas}),
    do: Enum.all?(schemas, &action_schema?/1)

  def action_schema?(%Zoi.Types.Codec{from: from, to: to}),
    do: action_schema?(from) and action_schema?(to)

  def action_schema?(_schema), do: false

  defp parse_schema(%Zoi.Types.Map{fields: fields} = schema, data)
       when is_list(fields) and is_map(data) do
    {Zoi.parse(open_schema(schema), data), %{}}
  end

  defp parse_schema(%Zoi.Types.Struct{fields: fields} = schema, data)
       when is_list(fields) and is_map(data) do
    cond do
      is_struct(data, schema.module) ->
        {_known, unknown} = split_known_fields(Map.from_struct(data), fields, schema.coerce)
        {Zoi.parse(open_schema(schema), data), unknown}

      schema.coerce ->
        data = if is_struct(data), do: Map.from_struct(data), else: data
        {known, unknown} = split_known_fields(data, fields, true)
        {Zoi.parse(open_schema(schema), known), unknown}

      true ->
        {Zoi.parse(open_schema(schema), data), %{}}
    end
  end

  defp parse_schema(schema, data), do: {Zoi.parse(open_schema(schema), data), %{}}

  defp open_schema(%Zoi.Types.Map{fields: fields} = schema) when is_list(fields) do
    %{schema | fields: open_fields(fields), unrecognized_keys: :preserve}
  end

  defp open_schema(%Zoi.Types.Map{} = schema) do
    %{schema | key_type: open_schema(schema.key_type), value_type: open_schema(schema.value_type)}
  end

  defp open_schema(%Zoi.Types.Struct{fields: fields} = schema) when is_list(fields) do
    %{schema | fields: open_fields(fields)}
  end

  defp open_schema(%Zoi.Types.Default{} = schema) do
    %{schema | inner: open_schema(schema.inner)}
  end

  defp open_schema(%Zoi.Types.Union{} = schema) do
    %{schema | schemas: Enum.map(schema.schemas, &open_schema/1)}
  end

  defp open_schema(%Zoi.Types.Intersection{} = schema) do
    %{schema | schemas: Enum.map(schema.schemas, &open_schema/1)}
  end

  defp open_schema(%Zoi.Types.Array{} = schema) do
    %{schema | inner: open_schema(schema.inner)}
  end

  defp open_schema(%Zoi.Types.Tuple{} = schema) do
    %{schema | fields: Enum.map(schema.fields, &open_schema/1)}
  end

  defp open_schema(%Zoi.Types.DiscriminatedUnion{} = schema) do
    %{schema | schemas: Map.new(schema.schemas, fn {key, value} -> {key, open_schema(value)} end)}
  end

  defp open_schema(%Zoi.Types.Lazy{fun: {module, function, args}} = schema) do
    %{schema | fun: fn -> module |> apply(function, args) |> open_schema() end}
  end

  defp open_schema(%Zoi.Types.Lazy{fun: fun} = schema) when is_function(fun, 0) do
    %{schema | fun: fn -> fun.() |> open_schema() end}
  end

  defp open_schema(%Zoi.Types.Codec{} = schema) do
    %{schema | from: open_schema(schema.from), to: open_schema(schema.to)}
  end

  defp open_schema(schema), do: schema

  defp open_fields(fields) do
    Enum.map(fields, fn {key, schema} -> {key, open_schema(schema)} end)
  end

  defp split_known_fields(data, fields, coerce?) do
    normalize_key = if coerce?, do: &to_string/1, else: &Function.identity/1

    known_keys =
      fields
      |> Enum.map(fn {key, _schema} -> normalize_key.(key) end)
      |> MapSet.new()

    data
    |> Map.to_list()
    |> Enum.split_with(fn {key, _value} -> MapSet.member?(known_keys, normalize_key.(key)) end)
    |> then(fn {known, unknown} -> {Map.new(known), Map.new(unknown)} end)
  end

  defp handle_validation_result({{:ok, validated}, unknown}, schema, _details) do
    validated = normalize_validated(schema, validated)

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

  defp normalize_validated(%Zoi.Types.Struct{fields: fields}, validated)
       when is_list(fields) and is_struct(validated) do
    validated
    |> Map.from_struct()
    |> Map.take(Enum.map(fields, &elem(&1, 0)))
  end

  defp normalize_validated(_schema, validated) when is_struct(validated),
    do: Map.from_struct(validated)

  defp normalize_validated(_schema, validated), do: validated

  defp format_zoi_error(%{path: path, message: message} = error) do
    %{
      path: path,
      message: message,
      code: Map.get(error, :code)
    }
  end
end
