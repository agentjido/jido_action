defmodule Jido.Flow.DSL.Expression do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Syntax

  @spec parse(term()) :: {:ok, term()} | {:error, Exception.t()}
  def parse(expression) do
    {:ok, parse!(expression)}
  rescue
    error in [ArgumentError] -> {:error, Error.validation_error(Exception.message(error))}
  end

  @spec parse_condition(term()) :: {:ok, Syntax.Condition.t()} | {:error, Exception.t()}
  def parse_condition(condition) do
    {:ok, parse_condition!(condition)}
  rescue
    error in [ArgumentError] -> {:error, Error.validation_error(Exception.message(error))}
  end

  defp parse!({:input, _meta, []}), do: Syntax.input([])
  defp parse!({:input, _meta, [path]}), do: Syntax.input(parse_path!(path))
  defp parse!({:context, _meta, []}), do: Syntax.context([])
  defp parse!({:context, _meta, [path]}), do: Syntax.context(parse_path!(path))
  defp parse!({:value, _meta, [value]}), do: Syntax.value(parse_literal!(value))

  defp parse!({:result, _meta, [node]}), do: Syntax.result(parse_node_name!(node))

  defp parse!({:result, _meta, [node, path]}) do
    Syntax.result(parse_node_name!(node), parse_path!(path))
  end

  defp parse!({:select, _meta, [source, path]}) do
    Syntax.select(parse!(source), parse_path!(path))
  end

  defp parse!({:item, _meta, []}), do: Syntax.item()
  defp parse!({:item, _meta, [path]}), do: Syntax.item(parse_path!(path))
  defp parse!({:item_index, _meta, []}), do: Syntax.item_index()
  defp parse!({:item_id, _meta, []}), do: Syntax.item_id()
  defp parse!({:accumulator, _meta, []}), do: Syntax.accumulator()
  defp parse!({:accumulator, _meta, [path]}), do: Syntax.accumulator(parse_path!(path))
  defp parse!({:state, _meta, []}), do: Syntax.state()
  defp parse!({:state, _meta, [path]}), do: Syntax.state(parse_path!(path))
  defp parse!({:iteration_index, _meta, []}), do: Syntax.iteration_index()
  defp parse!({:body_result, _meta, []}), do: Syntax.body_result()
  defp parse!({:body_result, _meta, [path]}), do: Syntax.body_result(parse_path!(path))

  defp parse!(%Syntax.Expr{} = expression), do: expression

  defp parse!(%{} = values) when not is_struct(values) do
    Map.new(values, fn {key, value} -> {parse_literal!(key), parse!(value)} end)
  end

  defp parse!({:%{}, _meta, pairs}) do
    Map.new(pairs, fn {key, value} -> {parse_literal!(key), parse!(value)} end)
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
       do: Syntax.value(value)

  defp parse!(expression), do: unsupported!(expression)

  defp parse_condition!(%Syntax.Condition{} = condition), do: condition

  defp parse_condition!({operator, _meta, [left, right]})
       when operator in [:==, :!=, :<, :<=, :>, :>=, :in] do
    syntax_operator =
      Map.fetch!(
        %{:== => :eq, :!= => :neq, :< => :lt, :<= => :lte, :> => :gt, :>= => :gte, :in => :in},
        operator
      )

    apply(Syntax, syntax_operator, [parse!(left), parse!(right)])
  end

  defp parse_condition!({operator, _meta, [left, right]}) when operator in [:and, :or] do
    conditions = [parse_condition!(left), parse_condition!(right)]
    apply(Syntax, if(operator == :and, do: :all, else: :any), [conditions])
  end

  defp parse_condition!({:not, _meta, [condition]}) do
    apply(Syntax, :not, [parse_condition!(condition)])
  end

  defp parse_condition!({operator, _meta, [left, right]})
       when operator in [:eq, :neq, :lt, :lte, :gt, :gte] do
    apply(Syntax, operator, [parse!(left), parse!(right)])
  end

  defp parse_condition!({operator, _meta, [conditions]}) when operator in [:all, :any] do
    apply(Syntax, operator, [Enum.map(conditions, &parse_condition!/1)])
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
    Map.new(pairs, fn {key, value} -> {parse_literal!(key), parse_literal!(value)} end)
  end

  defp parse_literal!(value), do: unsupported!(value)

  defp unsupported!(expression) do
    raise ArgumentError, "unsupported Flow expression: #{Macro.to_string(expression)}"
  end

  defp unsupported_condition!(condition) do
    raise ArgumentError, "unsupported Flow condition: #{Macro.to_string(condition)}"
  end
end
