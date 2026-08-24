defmodule Jido.Flow.DSL.Expression do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.{Condition, Ref}

  @spec parse(term()) :: {:ok, term()} | {:error, Exception.t()}
  def parse(expression) do
    {:ok, parse!(expression)}
  rescue
    error in [ArgumentError] ->
      {:error, Error.validation_error(Exception.message(error), source_details(expression))}
  end

  @spec parse_condition(term()) :: {:ok, Condition.t()} | {:error, Exception.t()}
  def parse_condition(condition) do
    {:ok, parse_condition!(condition)}
  rescue
    error in [ArgumentError] ->
      {:error, Error.validation_error(Exception.message(error), source_details(condition))}
  end

  defp parse!({:input, _meta, []}), do: Ref.input([])
  defp parse!({:input, _meta, [path]}), do: Ref.input(parse_path!(path))
  defp parse!({:context, _meta, []}), do: Ref.context([])
  defp parse!({:context, _meta, [path]}), do: Ref.context(parse_path!(path))
  defp parse!({:value, _meta, [value]}), do: Ref.value(parse_literal!(value))

  defp parse!({:result, _meta, [node]}), do: Ref.result(parse_node_name!(node))

  defp parse!({:result, _meta, [node, path]}) do
    Ref.result(parse_node_name!(node), parse_path!(path))
  end

  defp parse!({:select, _meta, [source, path]}) do
    select!(parse!(source), parse_path!(path))
  end

  defp parse!({:item, _meta, []}), do: Ref.item()
  defp parse!({:item, _meta, [path]}), do: Ref.item(parse_path!(path))
  defp parse!({:item_index, _meta, []}), do: Ref.item_index()
  defp parse!({:item_id, _meta, []}), do: Ref.item_id()
  defp parse!({:accumulator, _meta, []}), do: Ref.accumulator()
  defp parse!({:accumulator, _meta, [path]}), do: Ref.accumulator(parse_path!(path))
  defp parse!({:state, _meta, []}), do: Ref.state()
  defp parse!({:state, _meta, [path]}), do: Ref.state(parse_path!(path))
  defp parse!({:iteration_index, _meta, []}), do: Ref.iteration_index()
  defp parse!({:body_result, _meta, []}), do: Ref.body_result()
  defp parse!({:body_result, _meta, [path]}), do: Ref.body_result(parse_path!(path))

  defp parse!(%Ref{} = expression), do: expression

  defp parse!(%{} = values) when not is_struct(values) do
    Map.new(values, fn {key, value} -> {parse_literal!(key), parse!(value)} end)
  end

  defp parse!({:%{}, _meta, pairs}) do
    parse_map!(pairs, &parse!/1)
  end

  defp parse!(values) when is_list(values) do
    if Keyword.keyword?(values) do
      unsupported!(values)
    else
      Enum.map(values, &parse!/1)
    end
  end

  defp parse!(value)
       when is_nil(value) or is_boolean(value) or is_atom(value) or is_binary(value) or
              is_number(value),
       do: Ref.value(value)

  defp parse!(expression), do: unsupported!(expression)

  defp parse_condition!(%Condition{} = condition), do: condition

  defp parse_condition!({operator, _meta, [left, right]})
       when operator in [:==, :!=, :<, :<=, :>, :>=, :in] do
    syntax_operator =
      Map.fetch!(
        %{:== => :eq, :!= => :neq, :< => :lt, :<= => :lte, :> => :gt, :>= => :gte, :in => :in},
        operator
      )

    condition(syntax_operator, [parse!(left), parse!(right)])
  end

  defp parse_condition!({operator, _meta, [left, right]}) when operator in [:and, :or] do
    conditions = [parse_condition!(left), parse_condition!(right)]
    condition(if(operator == :and, do: :all, else: :any), conditions)
  end

  defp parse_condition!({:not, _meta, [condition]}) do
    condition(:not, [parse_condition!(condition)])
  end

  defp parse_condition!({operator, _meta, [left, right]})
       when operator in [:eq, :neq, :lt, :lte, :gt, :gte] do
    condition(operator, [parse!(left), parse!(right)])
  end

  defp parse_condition!({operator, _meta, [conditions]}) when operator in [:all, :any] do
    condition(operator, Enum.map(conditions, &parse_condition!/1))
  end

  defp parse_condition!(condition), do: unsupported_condition!(condition)

  defp parse_node_name!(name) when is_binary(name), do: name
  defp parse_node_name!(name) when is_atom(name) and not is_nil(name), do: name
  defp parse_node_name!(name), do: unsupported!(name)

  defp parse_path!(path) when is_atom(path) or is_binary(path) or is_integer(path), do: path
  defp parse_path!(path) when is_list(path), do: Enum.map(path, &parse_literal!/1)
  defp parse_path!(path), do: unsupported!(path)

  defp parse_literal!(value)
       when is_nil(value) or is_boolean(value) or is_atom(value) or is_binary(value) or
              is_number(value),
       do: value

  defp parse_literal!(values) when is_list(values), do: Enum.map(values, &parse_literal!/1)

  defp parse_literal!({:%{}, _meta, pairs}) do
    parse_map!(pairs, &parse_literal!/1)
  end

  defp parse_literal!(value), do: unsupported!(value)

  defp select!(%Ref{} = source, path),
    do: %{source | path: source.path ++ Ref.normalize_path(path)}

  defp select!(source, _path), do: unsupported!(source)

  defp condition(operator, operands), do: %Condition{operator: operator, operands: operands}

  defp parse_map!(pairs, parse_value) do
    parsed = Enum.map(pairs, fn {key, value} -> {parse_literal!(key), parse_value.(value)} end)

    case first_duplicate(Enum.map(parsed, &elem(&1, 0))) do
      {:ok, key} -> raise ArgumentError, "duplicate Flow map key: #{inspect(key)}"
      :none -> Map.new(parsed)
    end
  end

  defp first_duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, {:ok, value}}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
    |> case do
      %MapSet{} -> :none
      duplicate -> duplicate
    end
  end

  defp unsupported!(expression) do
    raise ArgumentError,
          "unsupported Flow expression: #{Macro.to_string(expression)}; " <>
            "use a Flow reference, literal, map, or list"
  end

  defp unsupported_condition!(condition) do
    raise ArgumentError,
          "unsupported Flow condition: #{Macro.to_string(condition)}; " <>
            "use ==, !=, <, <=, >, >=, in, and, or, not, or a Flow condition function"
  end

  defp source_details({_form, metadata, _arguments}) when is_list(metadata) do
    %{}
    |> maybe_put_source(:line, Keyword.get(metadata, :line))
    |> maybe_put_source(:column, Keyword.get(metadata, :column))
  end

  defp source_details(_expression), do: %{}

  defp maybe_put_source(details, _key, nil), do: details
  defp maybe_put_source(details, key, value), do: Map.put(details, key, value)
end
