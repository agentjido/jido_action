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
  def __parse_block__(block, env, context \\ %{}) do
    context = parser_context(context)

    block
    |> block_expressions()
    |> Enum.map(&parse_statement(&1, env, context))
  end

  defp parser_context(%{} = context) do
    %{
      profile: Map.get(context, :profile, :trusted),
      actions: Map.get(context, :actions, %{})
    }
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp parse_statement({:=, meta, [binding_ast, {:step, step_meta, args}]}, env, context) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_step(step_meta, args, env, binding, context)
  end

  defp parse_statement({:=, _meta, _args} = statement, env, _context) do
    unsupported!(
      "unsupported flow DSL binding assignment: #{Macro.to_string(statement)}",
      statement,
      env
    )
  end

  defp parse_statement({:group, meta, [[do: block]]}, env, context) do
    branches =
      block
      |> block_expressions()
      |> Enum.map(&parse_branch(&1, env, context))

    Syntax.operation(:group, %{branches: branches}, provenance: provenance_from_meta(meta))
  end

  defp parse_statement({:group, meta, args}, env, _context) do
    unsupported!(
      "unsupported flow DSL group: #{Macro.to_string({:group, meta, args})}",
      {
        :group,
        meta,
        args
      },
      env
    )
  end

  defp parse_statement({:step, meta, args}, env, context) do
    parse_step(meta, args, env, nil, context)
  end

  defp parse_statement({:return, _meta, [expr_ast]}, env, _context) do
    Syntax.operation(:return, %{expr: parse_expression(expr_ast, env)})
  end

  defp parse_statement(statement, env, _context) do
    unsupported!("unsupported flow DSL operation: #{Macro.to_string(statement)}", statement, env)
  end

  defp parse_branch({:branch, meta, [name_ast, [do: block]]}, env, context) do
    name = parse_atom!(name_ast, "branch name", meta, env)

    operations =
      block
      |> block_expressions()
      |> Enum.map(&parse_statement(&1, env, context))

    Syntax.branch(name, operations, provenance: provenance_from_meta(meta))
  end

  defp parse_branch(branch, env, _context) do
    unsupported!("unsupported flow DSL branch: #{Macro.to_string(branch)}", branch, env)
  end

  defp parse_step(meta, [name_ast, action_ast, input_ast], env, binding, context) do
    name = parse_atom!(name_ast, "step name", meta, env)
    action = parse_action_module!(action_ast, meta, env, context)
    {input, after_targets, annotations} = parse_step_input_and_after!(input_ast, env)

    attrs =
      %{name: name, action: action, input: input}
      |> maybe_put_binding(binding)
      |> maybe_put_after(after_targets)

    provenance =
      meta
      |> provenance_from_meta()
      |> Map.merge(annotations)

    Syntax.operation(:step, attrs, provenance: provenance)
  end

  defp parse_step(meta, args, env, _binding, _context) do
    unsupported_step_options!({:step, meta, args}, env)
  end

  defp parse_expression({:input, _meta, [path_ast]}, env) do
    Syntax.input(parse_path!(path_ast, env))
  end

  defp parse_expression({:context, _meta, [path_ast]}, env) do
    Syntax.context(parse_path!(path_ast, env))
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

  defp parse_action_module!(identifier, step_meta, env, %{profile: :stored, actions: actions})
       when is_binary(identifier) or (is_atom(identifier) and not is_nil(identifier)) do
    case Map.fetch(actions, identifier) do
      {:ok, action} ->
        action

      :error ->
        unknown_action_identifier!(identifier, step_meta, env)
    end
  end

  defp parse_action_module!({:__aliases__, _meta, _parts} = ast, _step_meta, env, %{
         profile: :stored
       }) do
    unsupported!(
      "stored flow action modules must use registered identifiers: #{Macro.to_string(ast)}",
      ast,
      env
    )
  end

  defp parse_action_module!(module, _step_meta, _env, _context)
       when is_atom(module) and not is_nil(module),
       do: module

  defp parse_action_module!({:__aliases__, _meta, _parts} = ast, _step_meta, env, _context) do
    case Macro.expand(ast, env) do
      module when is_atom(module) and not is_nil(module) ->
        module

      _expanded ->
        unsupported!("unsupported flow DSL action module: #{Macro.to_string(ast)}", ast, env)
    end
  end

  defp parse_action_module!(ast, _step_meta, env, _context) do
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

  defp parse_step_input_and_after!(options, env) when is_list(options) do
    if Keyword.keyword?(options) do
      parse_step_options!(options, env)
    else
      {parse_expression(options, env), nil, %{}}
    end
  end

  defp parse_step_input_and_after!(input_ast, env),
    do: {parse_expression(input_ast, env), nil, %{}}

  defp parse_step_options!(options, env) do
    with :ok <- validate_step_options!(options, env) do
      input = options |> Keyword.fetch!(:with) |> parse_expression(env)

      after_targets =
        case Keyword.fetch(options, :after) do
          {:ok, targets} -> parse_after_targets!(targets, env)
          :error -> nil
        end

      annotations = parse_step_annotations!(options, env)

      {input, after_targets, annotations}
    end
  end

  defp validate_step_options!(options, env) do
    allowed_keys = [:with, :after, :label, :tags, :note]
    keys = Keyword.keys(options)
    duplicate_key = duplicate_step_option_key(keys, allowed_keys)

    cond do
      Enum.any?(keys, &(&1 not in allowed_keys)) ->
        unsupported_step_options!(options, env)

      not Keyword.has_key?(options, :with) ->
        unsupported_step_options!(options, env)

      duplicate_key ->
        unsupported_step_options!(Keyword.take(options, [duplicate_key]), env)

      true ->
        :ok
    end
  end

  defp parse_step_annotations!(options, env) do
    options
    |> Keyword.take([:label, :tags, :note])
    |> Enum.map(fn {field, value_ast} ->
      {field, parse_step_annotation!(field, value_ast, env)}
    end)
    |> Map.new()
  end

  defp parse_step_annotation!(field, value_ast, env) when field in [:label, :note] do
    value = parse_literal!(value_ast, env)

    if is_binary(value) do
      value
    else
      unsupported_annotation!(field, value_ast, env)
    end
  end

  defp parse_step_annotation!(:tags, tags_ast, env) when is_list(tags_ast) do
    if Keyword.keyword?(tags_ast) do
      unsupported_annotation!(:tags, tags_ast, env)
    else
      tags = Enum.map(tags_ast, &parse_literal!(&1, env))

      if Enum.all?(tags, &(is_binary(&1) or (is_atom(&1) and not is_nil(&1)))) do
        tags
      else
        unsupported_annotation!(:tags, tags_ast, env)
      end
    end
  end

  defp parse_step_annotation!(field, value_ast, env) do
    unsupported_annotation!(field, value_ast, env)
  end

  defp duplicate_step_option_key(keys, allowed_keys) do
    Enum.find(allowed_keys, fn allowed_key ->
      Enum.count(keys, &(&1 == allowed_key)) > 1
    end)
  end

  defp parse_after_targets!(targets, env) when is_list(targets) do
    if Keyword.keyword?(targets) do
      unsupported_after_target!(targets, env)
    else
      Enum.map(targets, &parse_after_target!(&1, env))
    end
  end

  defp parse_after_targets!(target, env), do: parse_after_target!(target, env)

  defp parse_after_target!(target, _env) when is_atom(target) and not is_nil(target), do: target

  defp parse_after_target!({name, meta, context}, _env)
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)) do
    Syntax.binding(name)
  end

  defp parse_after_target!(target, env), do: unsupported_after_target!(target, env)

  defp maybe_put_binding(attrs, nil), do: attrs
  defp maybe_put_binding(attrs, binding), do: Map.put(attrs, :binding, binding)

  defp maybe_put_after(attrs, nil), do: attrs
  defp maybe_put_after(attrs, after_targets), do: Map.put(attrs, :after, after_targets)

  defp provenance_from_meta(meta) do
    meta
    |> Keyword.take([:line, :column])
    |> Map.new()
  end

  defp unsupported_step_options!(statement, env) do
    unsupported!(
      "unsupported flow DSL step options: #{Macro.to_string(statement)}",
      statement,
      env
    )
  end

  defp unsupported_after_target!(target, env) do
    unsupported!(
      "unsupported flow DSL after target: #{Macro.to_string(target)}",
      target,
      env
    )
  end

  defp unknown_action_identifier!(identifier, meta, env) do
    unsupported_with_meta!(
      "unknown flow action identifier: #{inspect(identifier)}",
      meta,
      env
    )
  end

  defp unsupported_annotation!(field, value, env) do
    unsupported!(
      "unsupported flow DSL annotation #{field}: #{Macro.to_string(value)}",
      value,
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
