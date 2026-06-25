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

  defp parse_statement({:=, meta, [binding_ast, {:step, step_meta, args}]}, env) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_step(step_meta, args, env, binding)
  end

  defp parse_statement({:=, _meta, _args} = statement, env) do
    unsupported!(
      "unsupported flow DSL binding assignment: #{Macro.to_string(statement)}",
      statement,
      env
    )
  end

  defp parse_statement({:step, meta, args}, env) do
    parse_step(meta, args, env, nil)
  end

  defp parse_statement({:return, _meta, [expr_ast]}, env) do
    Syntax.operation(:return, %{expr: parse_expression(expr_ast, env)})
  end

  defp parse_statement(statement, env) do
    unsupported!("unsupported flow DSL operation: #{Macro.to_string(statement)}", statement, env)
  end

  defp parse_step(meta, [name_ast, action_ast, input_ast], env, binding) do
    name = parse_atom!(name_ast, "step name", meta, env)
    action = parse_action_module!(action_ast, env)
    input = parse_step_input!(input_ast, env)

    attrs =
      %{name: name, action: action, input: input}
      |> maybe_put_binding(binding)

    Syntax.operation(:step, attrs, provenance: provenance_from_meta(meta))
  end

  defp parse_step(meta, args, env, _binding) do
    unsupported_step_options!({:step, meta, args}, env)
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

  defp parse_expression({:select, _meta, [source_ast, path_ast]}, env) do
    Syntax.select(parse_expression(source_ast, env), parse_path!(path_ast, env))
  end

  defp parse_expression({:shape, _meta, [data_ast]}, env) do
    Syntax.shape(parse_expression(data_ast, env))
  end

  defp parse_expression({:%{}, _meta, pairs}, env) do
    Map.new(pairs, fn {key_ast, value_ast} ->
      {parse_literal!(key_ast, env), parse_expression(value_ast, env)}
    end)
  end

  defp parse_expression(values, env) when is_list(values) do
    if Keyword.keyword?(values) do
      unsupported!(
        "unsupported flow DSL expression: #{Macro.to_string(values)}",
        values,
        env
      )
    else
      Enum.map(values, &parse_expression(&1, env))
    end
  end

  defp parse_expression({name, meta, context}, _env)
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)) do
    Syntax.binding(name)
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

  defp parse_path!(path, _env) when is_atom(path) or is_binary(path) or is_integer(path), do: path

  defp parse_path!(path, env) when is_list(path) do
    Enum.map(path, &parse_literal!(&1, env))
  end

  defp parse_path!(path, env), do: parse_literal!(path, env)

  defp parse_atom!(atom, _label, _meta, _env) when is_atom(atom) and not is_nil(atom), do: atom

  defp parse_atom!(ast, label, _meta, env) do
    unsupported!("unsupported flow DSL #{label}: #{Macro.to_string(ast)}", ast, env)
  end

  defp parse_binding_lhs!({name, _meta, context}, _assignment_meta, _env)
       when is_atom(name) and is_atom(context) do
    name
  end

  defp parse_binding_lhs!(ast, assignment_meta, env) do
    unsupported_with_meta!(
      "unsupported flow DSL binding assignment: #{Macro.to_string(ast)}",
      assignment_meta,
      env
    )
  end

  defp parse_action_module!(module, _env) when is_atom(module) and not is_nil(module), do: module

  defp parse_action_module!({:__aliases__, _meta, parts}, _env) do
    Module.concat(parts)
  end

  defp parse_action_module!(ast, env) do
    unsupported!("unsupported flow DSL action module: #{Macro.to_string(ast)}", ast, env)
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

  defp parse_step_input!([with: input_ast], env), do: parse_expression(input_ast, env)

  defp parse_step_input!(options, env) when is_list(options) do
    if Keyword.keyword?(options) do
      unsupported!(
        "unsupported flow DSL step options: #{Macro.to_string(options)}",
        options,
        env
      )
    else
      parse_expression(options, env)
    end
  end

  defp parse_step_input!(input_ast, env), do: parse_expression(input_ast, env)

  defp maybe_put_binding(attrs, nil), do: attrs
  defp maybe_put_binding(attrs, binding), do: Map.put(attrs, :binding, binding)

  defp provenance_from_meta(meta) do
    case Keyword.get(meta, :line) do
      nil -> %{}
      line -> %{line: line}
    end
  end

  defp unsupported_step_options!(statement, env) do
    unsupported!(
      "unsupported flow DSL step options: #{Macro.to_string(statement)}",
      statement,
      env
    )
  end

  defp unsupported!(message, ast, env) do
    raise CompileError,
      file: env.file,
      line: ast |> ast_meta() |> Keyword.get(:line, env.line),
      description: message
  end

  defp unsupported_with_meta!(message, meta, env) do
    raise CompileError,
      file: env.file,
      line: Keyword.get(meta, :line, env.line),
      description: message
  end

  defp ast_meta({_form, meta, _args}) when is_list(meta), do: meta
  defp ast_meta(_ast), do: []
end
