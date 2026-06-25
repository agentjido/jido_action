defmodule Jido.Flow.DSL do
  @moduledoc false

  alias Jido.Flow.Syntax

  defmacro flow(do: block) do
    operations = __parse_block__(block, __CALLER__)
    escaped = Macro.escape(operations)

    quote bind_quoted: [operations: escaped] do
      @__jido_flow_operations__ operations
    end
  end

  @doc false
  def __parse_block__(block, env) do
    block
    |> block_expressions()
    |> Enum.map(&parse_statement(&1, env))
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp parse_statement({:step, meta, args}, env) when length(args) in [3, 4] do
    [name_ast, action_ast, input_ast | rest] = args
    opts_ast = List.first(rest) || []
    name = parse_atom!(name_ast, "step name", meta, env)
    action = Macro.expand(action_ast, env)
    input = parse_expression(input_ast, env)
    opts = parse_opts!(opts_ast, meta, env)

    Syntax.operation(:step, %{name: name, action: action, input: input})
    |> put_optional_attr(:bind, Keyword.get(opts, :bind))
  end

  defp parse_statement({:bind, meta, [name_ast, expr_ast]}, env) do
    name = parse_atom!(name_ast, "binding name", meta, env)
    Syntax.operation(:bind, %{name: name, expr: parse_expression(expr_ast, env)})
  end

  defp parse_statement({:return, _meta, [expr_ast]}, env) do
    Syntax.operation(:return, %{expr: parse_expression(expr_ast, env)})
  end

  defp parse_statement(statement, env) do
    unsupported!("unsupported flow DSL operation: #{Macro.to_string(statement)}", statement, env)
  end

  defp parse_expression({:input, _meta, [path_ast]}, env) do
    Syntax.input(parse_path!(path_ast, env))
  end

  defp parse_expression({:value, _meta, [value_ast]}, env) do
    Syntax.value(parse_literal!(value_ast, env))
  end

  defp parse_expression({:result, _meta, [node_ast]}, env) do
    Syntax.result(parse_atom!(node_ast, "result node", [], env))
  end

  defp parse_expression({:result, _meta, [node_ast, path_ast]}, env) do
    Syntax.result(parse_atom!(node_ast, "result node", [], env), parse_path!(path_ast, env))
  end

  defp parse_expression({:var, _meta, [name_ast]}, env) do
    Syntax.var(parse_atom!(name_ast, "binding name", [], env))
  end

  defp parse_expression({:var, _meta, [name_ast, path_ast]}, env) do
    Syntax.var(parse_atom!(name_ast, "binding name", [], env), parse_path!(path_ast, env))
  end

  defp parse_expression({:%{}, _meta, pairs}, env) do
    Map.new(pairs, fn {key_ast, value_ast} ->
      {parse_literal!(key_ast, env), parse_expression(value_ast, env)}
    end)
  end

  defp parse_expression(value, env) when is_atom(value) or is_binary(value) or is_number(value) do
    Syntax.value(parse_literal!(value, env))
  end

  defp parse_expression(expression, env) do
    unsupported!(
      "unsupported flow DSL expression: #{Macro.to_string(expression)}",
      expression,
      env
    )
  end

  defp parse_opts!(opts, _meta, _env) when is_list(opts), do: opts

  defp parse_opts!(opts, _meta, env) do
    unsupported!("unsupported flow DSL options: #{Macro.to_string(opts)}", opts, env)
  end

  defp parse_path!(path, _env) when is_atom(path) or is_binary(path) or is_integer(path), do: path

  defp parse_path!(path, env) when is_list(path) do
    Enum.map(path, &parse_literal!(&1, env))
  end

  defp parse_path!(path, env), do: parse_literal!(path, env)

  defp parse_atom!(atom, _label, _meta, _env) when is_atom(atom) and not is_nil(atom), do: atom

  defp parse_atom!(ast, label, _meta, env) do
    unsupported!("unsupported flow DSL #{label}: #{Macro.to_string(ast)}", ast, env)
  end

  defp parse_literal!(value, _env)
       when is_nil(value) or is_boolean(value) or is_atom(value) or is_binary(value) or
              is_number(value),
       do: value

  defp parse_literal!({:%{}, _meta, pairs}, env) do
    Map.new(pairs, fn {key, value} ->
      {parse_literal!(key, env), parse_literal!(value, env)}
    end)
  end

  defp parse_literal!(values, env) when is_list(values),
    do: Enum.map(values, &parse_literal!(&1, env))

  defp parse_literal!(value, env) do
    unsupported!("unsupported flow DSL expression: #{Macro.to_string(value)}", value, env)
  end

  defp put_optional_attr(%Syntax.Operation{} = operation, _key, nil), do: operation

  defp put_optional_attr(%Syntax.Operation{} = operation, key, value) do
    %{operation | attrs: Map.put(operation.attrs, key, value)}
  end

  defp unsupported!(message, ast, env) do
    meta = if is_tuple(ast), do: elem(ast, 1), else: []

    raise CompileError,
      file: env.file,
      line: Keyword.get(meta, :line, env.line),
      description: message
  end
end
