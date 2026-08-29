defmodule Jido.Action.Validation do
  @moduledoc false

  alias Jido.Action.Error

  @doc false
  @spec open_validate(term(), term(), map()) ::
          {:ok, term()} | {:error, Error.InvalidInputError.t()}
  def open_validate([], data, _details), do: {:ok, data}

  def open_validate(schema, data, details) when is_map(details) do
    if zoi_schema?(schema) do
      safely_validate(details, fn ->
        schema
        |> parse_schema(data)
        |> handle_validation_result(schema, details)
      end)
    else
      {:error, Error.validation_error("Unsupported schema type", details)}
    end
  end

  @doc false
  @spec open_validate_preserving_shape(term(), term(), map()) ::
          {:ok, term()} | {:error, Error.InvalidInputError.t()}
  def open_validate_preserving_shape([], data, _details), do: {:ok, data}

  def open_validate_preserving_shape(schema, data, details) when is_map(details) do
    if zoi_schema?(schema) do
      safely_validate(details, fn ->
        schema
        |> parse_schema(data)
        |> handle_shape_preserving_result(schema, details)
      end)
    else
      {:error, Error.validation_error("Unsupported schema type", details)}
    end
  end

  defp safely_validate(details, validate) do
    validate.()
  rescue
    exception ->
      {:error,
       Error.validation_error(
         "schema validation failed",
         Map.merge(details, %{
           exception: exception.__struct__,
           reason: Exception.message(exception)
         })
       )}
  catch
    kind, reason ->
      {:error,
       Error.validation_error(
         "schema validation failed",
         Map.merge(details, %{failure_kind: kind, reason: inspect(reason)})
       )}
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

  def action_schema?(%Zoi.Types.Lazy{} = schema) do
    case resolve_lazy(schema) do
      %Zoi.Types.Lazy{} -> false
      resolved -> action_schema?(resolved)
    end
  rescue
    _exception -> false
  end

  def action_schema?(%Zoi.Types.Literal{value: value}), do: is_map(value)
  def action_schema?(%Zoi.Types.Default{inner: inner}), do: action_schema?(inner)

  def action_schema?(%Zoi.Types.Union{schemas: schemas}),
    do: Enum.any?(schemas, &action_schema?/1)

  def action_schema?(%Zoi.Types.Intersection{schemas: schemas}),
    do: Enum.all?(schemas, &action_schema?/1)

  def action_schema?(%Zoi.Types.Codec{from: from, to: to}),
    do: action_schema?(from) and action_schema?(to)

  def action_schema?(_schema), do: false

  defp resolve_lazy(%Zoi.Types.Lazy{fun: {module, function, args}}),
    do: apply(module, function, args)

  defp resolve_lazy(%Zoi.Types.Lazy{fun: fun}), do: fun.()

  defp parse_schema(%Zoi.Types.Map{fields: fields} = schema, data)
       when is_list(fields) and is_map(data) do
    {Zoi.parse(open_root_object(schema), data), %{}}
  end

  defp parse_schema(
         %Zoi.Types.Struct{fields: fields, unrecognized_keys: :error} = schema,
         data
       )
       when is_list(fields) and is_map(data) do
    {Zoi.parse(schema, data), %{}}
  end

  defp parse_schema(%Zoi.Types.Struct{fields: fields} = schema, data)
       when is_list(fields) and is_map(data) do
    cond do
      is_struct(data, schema.module) ->
        {_known, unknown} = split_known_fields(Map.from_struct(data), fields, schema.coerce)
        {Zoi.parse(schema, data), unknown}

      schema.coerce ->
        data = if is_struct(data), do: Map.from_struct(data), else: data
        {known, unknown} = split_known_fields(data, fields, true)
        {Zoi.parse(schema, known), unknown}

      true ->
        {Zoi.parse(schema, data), %{}}
    end
  end

  defp parse_schema(schema, data), do: {Zoi.parse(schema, data), %{}}

  defp open_root_object(%Zoi.Types.Map{unrecognized_keys: :strip} = schema) do
    %{schema | unrecognized_keys: :preserve}
  end

  defp open_root_object(schema), do: schema

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

  defp handle_shape_preserving_result({{:ok, validated}, unknown}, schema, _details) do
    if is_map(validated) and not is_struct(validated) and object_schema?(schema) do
      {:ok, Map.merge(unknown, validated)}
    else
      {:ok, validated}
    end
  end

  defp handle_shape_preserving_result({{:error, errors}, _unknown}, _schema, details) do
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
