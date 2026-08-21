defmodule Jido.Flow.DSL do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.{ActionRegistry, Syntax}

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
      actions: Map.get(context, :actions, %{}),
      state_schemas: Map.get(context, :state_schemas, %{}),
      source: Map.get(context, :source, false)
    }
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp parse_statement({:=, meta, [binding_ast, {:step, step_meta, args}]}, env, context) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_step(step_meta, args, env, binding, context)
  end

  defp parse_statement({:=, meta, [binding_ast, {:choose, choice_meta, args}]}, env, context) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_choice(choice_meta, args, env, binding, context)
  end

  defp parse_statement({:=, meta, [binding_ast, {:map, map_meta, args}]}, env, context) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_map(map_meta, args, env, binding, context)
  end

  defp parse_statement({:=, meta, [binding_ast, {:reduce, reduce_meta, args}]}, env, context) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_reduce(reduce_meta, args, env, binding, context)
  end

  defp parse_statement({:=, meta, [binding_ast, {:loop, loop_meta, args}]}, env, context) do
    binding = parse_binding_lhs!(binding_ast, meta, env)
    parse_loop(loop_meta, args, env, binding, context)
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

  defp parse_statement({:choose, meta, args}, env, context) do
    parse_choice(meta, args, env, nil, context)
  end

  defp parse_statement({:map, meta, args}, env, context) do
    parse_map(meta, args, env, nil, context)
  end

  defp parse_statement({:reduce, meta, args}, env, context) do
    parse_reduce(meta, args, env, nil, context)
  end

  defp parse_statement({:loop, meta, args}, env, context) do
    parse_loop(meta, args, env, nil, context)
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

  defp parse_step(meta, [action_ast, input_ast], env, binding, context)
       when is_atom(binding) and not is_nil(binding) do
    action = parse_action_module!(action_ast, meta, env, context)
    {input, after_targets, annotations} = parse_step_input_and_after!(input_ast, env)

    attrs =
      %{action: action, input: input}
      |> maybe_put_binding(binding)
      |> maybe_put_after(after_targets)

    provenance =
      meta
      |> provenance_from_meta()
      |> Map.merge(annotations)

    Syntax.operation(:step, attrs, provenance: provenance)
  end

  defp parse_step(meta, [name_ast, action_ast, input_ast], env, binding, context) do
    name = parse_node_name!(name_ast, "step name", meta, env)
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

  defp parse_choice(meta, args, env, binding, context) do
    {name_ast, choice_options, block} = parse_choice_arguments!(meta, args, env)
    name = parse_node_name!(name_ast, "choice name", meta, env)
    after_targets = parse_choice_after!(choice_options, env)
    {options, fallback} = parse_choice_block!(block, env, context)

    attrs =
      %{name: name, options: options, fallback: fallback}
      |> maybe_put_binding(binding)
      |> maybe_put_after(after_targets)

    Syntax.operation(:choice, attrs, provenance: provenance_from_meta(meta))
  end

  defp parse_map(meta, [name_ast, collection_ast, options], env, binding, context)
       when is_list(options) do
    validate_collection_options!(:map, options, env)

    attrs =
      %{
        name: parse_node_name!(name_ast, "map name", meta, env),
        collection: parse_expression(collection_ast, env),
        action: parse_action_module!(Keyword.fetch!(options, :run), meta, env, context),
        input: options |> Keyword.fetch!(:with) |> parse_expression(env),
        on_error: options |> Keyword.get(:on_error, :fail_fast) |> parse_map_mode!(env)
      }
      |> maybe_put_binding(binding)
      |> maybe_put_after_option(options, env)

    Syntax.operation(:map, attrs, provenance: provenance_from_meta(meta))
  end

  defp parse_map(meta, args, env, _binding, _context) do
    unsupported_collection_options!(:map, {:map, meta, args}, env)
  end

  defp parse_reduce(meta, [name_ast, collection_ast, options], env, binding, context)
       when is_list(options) do
    validate_collection_options!(:reduce, options, env)

    attrs =
      %{
        name: parse_node_name!(name_ast, "reduce name", meta, env),
        collection: parse_expression(collection_ast, env),
        initial: options |> Keyword.fetch!(:initial) |> parse_expression(env),
        action: parse_action_module!(Keyword.fetch!(options, :run), meta, env, context),
        input: options |> Keyword.fetch!(:with) |> parse_expression(env)
      }
      |> maybe_put_binding(binding)
      |> maybe_put_after_option(options, env)

    Syntax.operation(:reduce, attrs, provenance: provenance_from_meta(meta))
  end

  defp parse_reduce(meta, args, env, _binding, _context) do
    unsupported_collection_options!(:reduce, {:reduce, meta, args}, env)
  end

  defp parse_loop(meta, [name_ast, options], env, binding, context) when is_list(options) do
    validate_loop_options!(options, env)
    name = parse_node_name!(name_ast, "loop name", meta, env)

    attrs =
      %{
        name: name,
        action: parse_action_module!(Keyword.fetch!(options, :run), meta, env, context),
        input: options |> Keyword.fetch!(:with) |> parse_expression(env),
        state: parse_loop_state!(Keyword.fetch!(options, :state), name, env, context)
      }
      |> maybe_put_loop_termination(options, env)
      |> maybe_put_binding(binding)
      |> maybe_put_after_option(options, env)

    Syntax.operation(:loop, attrs, provenance: provenance_from_meta(meta))
  end

  defp parse_loop(meta, args, env, _binding, _context) do
    unsupported_loop_options!({:loop, meta, args}, env)
  end

  defp validate_loop_options!(options, env) do
    allowed = [:run, :with, :state, :while, :until, :repeat, :max_iterations, :after]
    required = [:run, :with, :state]

    valid? =
      if Keyword.keyword?(options) do
        keys = Keyword.keys(options)

        Enum.all?(keys, &(&1 in allowed)) and
          Enum.all?(required, &Keyword.has_key?(options, &1)) and
          is_nil(duplicate_step_option_key(keys, allowed))
      else
        false
      end

    unless valid?, do: unsupported_loop_options!(options, env)
  end

  defp parse_loop_state!(state, node, env, context) when is_list(state) do
    allowed = [:schema, :initial, :update]

    valid? =
      if Keyword.keyword?(state) do
        keys = Keyword.keys(state)

        Enum.all?(keys, &(&1 in allowed)) and
          Enum.all?(allowed, &Keyword.has_key?(state, &1)) and
          is_nil(duplicate_step_option_key(keys, allowed))
      else
        false
      end

    unless valid?, do: unsupported_loop_state!(state, env)

    %{
      schema: parse_loop_schema!(Keyword.fetch!(state, :schema), node, env, context),
      initial: state |> Keyword.fetch!(:initial) |> parse_expression(env),
      update: state |> Keyword.fetch!(:update) |> parse_expression(env)
    }
  end

  defp parse_loop_state!(state, _node, env, _context), do: unsupported_loop_state!(state, env)

  defp parse_loop_schema!(schema_ast, node, env, %{source: true, state_schemas: schemas}) do
    identifier = parse_literal!(schema_ast, env)

    case Map.fetch(schemas, identifier) do
      {:ok, schema} ->
        schema

      :error ->
        error =
          Error.validation_error(
            "unknown loop state schema identifier: #{inspect(identifier)}",
            %{schema: identifier, node: to_string(node), path: [:state, :schema]}
          )

        throw({:jido_flow_parser_error, error})
    end
  end

  defp parse_loop_schema!(schema_ast, _node, env, _context), do: parse_literal!(schema_ast, env)

  defp maybe_put_loop_termination(attrs, options, env) do
    attrs
    |> maybe_put_parsed_condition(options, :while, env)
    |> maybe_put_parsed_condition(options, :until, env)
    |> maybe_put_parsed_literal(options, :repeat, env)
    |> maybe_put_parsed_literal(options, :max_iterations, env)
  end

  defp maybe_put_parsed_condition(attrs, options, field, env) do
    case Keyword.fetch(options, field) do
      {:ok, condition} -> Map.put(attrs, field, parse_condition!(condition, env))
      :error -> attrs
    end
  end

  defp maybe_put_parsed_literal(attrs, options, field, env) do
    case Keyword.fetch(options, field) do
      {:ok, value} -> Map.put(attrs, field, parse_literal!(value, env))
      :error -> attrs
    end
  end

  defp validate_collection_options!(kind, options, env) do
    {allowed, required} =
      case kind do
        :map -> {[:run, :with, :on_error, :after], [:run, :with]}
        :reduce -> {[:initial, :run, :with, :after], [:initial, :run, :with]}
      end

    valid? =
      if Keyword.keyword?(options) do
        keys = Keyword.keys(options)

        Enum.all?(keys, &(&1 in allowed)) and
          Enum.all?(required, &Keyword.has_key?(options, &1)) and
          is_nil(duplicate_step_option_key(keys, allowed))
      else
        false
      end

    unless valid? do
      unsupported_collection_options!(kind, options, env)
    end
  end

  defp parse_map_mode!(mode, _env) when mode in [:fail_fast, :collect_errors], do: mode

  defp parse_map_mode!(mode, env) do
    unsupported!(
      "unsupported flow DSL map on_error: #{Macro.to_string(mode)}",
      mode,
      env
    )
  end

  defp maybe_put_after_option(attrs, options, env) do
    case Keyword.fetch(options, :after) do
      {:ok, targets} -> Map.put(attrs, :after, parse_after_targets!(targets, env))
      :error -> attrs
    end
  end

  defp parse_choice_arguments!(_meta, [name_ast, [do: block]], _env), do: {name_ast, [], block}

  defp parse_choice_arguments!(meta, [name_ast, options, [do: block]], env)
       when is_list(options) do
    unless Keyword.keyword?(options) do
      unsupported_choice!({:choose, meta, [name_ast, options, [do: block]]}, env)
    end

    {name_ast, options, block}
  end

  defp parse_choice_arguments!(meta, args, env) do
    unsupported_choice!({:choose, meta, args}, env)
  end

  defp parse_choice_after!(options, env) do
    keys = Keyword.keys(options)

    cond do
      Enum.any?(keys, &(&1 != :after)) ->
        unsupported_choice_options!(options, env)

      Enum.count(keys, &(&1 == :after)) > 1 ->
        unsupported_choice_options!(options, env)

      true ->
        case Keyword.fetch(options, :after) do
          {:ok, targets} -> parse_after_targets!(targets, env)
          :error -> nil
        end
    end
  end

  defp parse_choice_block!(block, env, context) do
    statements = block_expressions(block)

    {options, fallback} =
      statements
      |> Enum.reduce({[], nil}, fn statement, {options, fallback} ->
        case statement do
          {:option, _meta, _args} ->
            if fallback do
              unsupported_choice!(statement, env)
            end

            {[parse_choice_option!(statement, env, context) | options], fallback}

          {:otherwise, _meta, _args} ->
            if fallback do
              unsupported_choice!(statement, env)
            end

            {options, parse_choice_fallback!(statement, env, context)}

          _other ->
            unsupported_choice!(statement, env)
        end
      end)

    cond do
      options == [] ->
        unsupported_choice!(block, env)

      is_nil(fallback) ->
        unsupported_choice!(block, env)

      true ->
        {Enum.reverse(options), fallback}
    end
  end

  defp parse_choice_option!({:option, meta, [name_ast, options]}, env, context)
       when is_list(options) do
    if Keyword.keyword?(options) do
      validate_choice_target_options!(options, :option, env)

      Syntax.option(
        parse_node_name!(name_ast, "choice option name", meta, env),
        parse_condition!(Keyword.fetch!(options, :when), env),
        parse_action_module!(Keyword.fetch!(options, :run), meta, env, context),
        parse_expression(Keyword.fetch!(options, :with), env)
      )
    else
      unsupported_choice!({:option, meta, [name_ast, options]}, env)
    end
  end

  defp parse_choice_option!(statement, env, _context), do: unsupported_choice!(statement, env)

  defp parse_choice_fallback!({:otherwise, meta, [options]}, env, context)
       when is_list(options) do
    if Keyword.keyword?(options) do
      validate_choice_target_options!(options, :otherwise, env)

      Syntax.fallback(
        parse_action_module!(Keyword.fetch!(options, :run), meta, env, context),
        parse_expression(Keyword.fetch!(options, :with), env)
      )
    else
      unsupported_choice!({:otherwise, meta, [options]}, env)
    end
  end

  defp parse_choice_fallback!(statement, env, _context), do: unsupported_choice!(statement, env)

  defp validate_choice_target_options!(options, kind, env) do
    allowed_keys = if kind == :option, do: [:when, :run, :with], else: [:run, :with]
    keys = Keyword.keys(options)

    if Enum.any?(keys, &(&1 not in allowed_keys)) or
         Enum.any?(allowed_keys, &(not Keyword.has_key?(options, &1))) or
         Enum.any?(allowed_keys, &(Enum.count(keys, fn key -> key == &1 end) > 1)) do
      unsupported_choice_options!(options, env)
    end
  end

  defp parse_condition!({operator, _meta, operands}, env)
       when operator in [:eq, :neq, :lt, :lte, :gt, :gte, :in] and is_list(operands) do
    if length(operands) == 2 do
      apply(Syntax, operator, Enum.map(operands, &parse_expression(&1, env)))
    else
      unsupported_choice_condition!({operator, [], operands}, env)
    end
  end

  defp parse_condition!({operator, _meta, [conditions]}, env) when operator in [:all, :any] do
    if is_list(conditions) and not Keyword.keyword?(conditions) do
      apply(Syntax, operator, [Enum.map(conditions, &parse_condition!(&1, env))])
    else
      unsupported_choice_condition!({operator, [], [conditions]}, env)
    end
  end

  defp parse_condition!({:not, _meta, [condition]}, env),
    do: apply(Syntax, :not, [parse_condition!(condition, env)])

  defp parse_condition!(condition, env), do: unsupported_choice_condition!(condition, env)

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
    Syntax.result(parse_node_name!(node_ast, "result node", [], env))
  end

  defp parse_expression({:result, _meta, [node_ast, path_ast]}, env) do
    Syntax.result(parse_node_name!(node_ast, "result node", [], env), parse_path!(path_ast, env))
  end

  defp parse_expression({:select, _meta, [source_ast, path_ast]}, env) do
    Syntax.select(parse_expression(source_ast, env), parse_path!(path_ast, env))
  end

  defp parse_expression({:item, _meta, []}, _env), do: Syntax.item()

  defp parse_expression({:item, _meta, [path_ast]}, env) do
    Syntax.item(parse_path!(path_ast, env))
  end

  defp parse_expression({:item_index, _meta, []}, _env), do: Syntax.item_index()
  defp parse_expression({:item_id, _meta, []}, _env), do: Syntax.item_id()

  defp parse_expression({:accumulator, _meta, []}, _env), do: Syntax.accumulator()

  defp parse_expression({:accumulator, _meta, [path_ast]}, env) do
    Syntax.accumulator(parse_path!(path_ast, env))
  end

  defp parse_expression({:state, _meta, []}, _env), do: Syntax.state()

  defp parse_expression({:state, _meta, [path_ast]}, env) do
    Syntax.state(parse_path!(path_ast, env))
  end

  defp parse_expression({:iteration_index, _meta, []}, _env), do: Syntax.iteration_index()

  defp parse_expression({:body_result, _meta, []}, _env), do: Syntax.body_result()

  defp parse_expression({:body_result, _meta, [path_ast]}, env) do
    Syntax.body_result(parse_path!(path_ast, env))
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

  defp parse_node_name!(name, _label, _meta, _env)
       when (is_atom(name) and not is_nil(name)) or is_binary(name),
       do: name

  defp parse_node_name!(ast, label, _meta, env) do
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
    identifier = if is_atom(identifier), do: Atom.to_string(identifier), else: identifier

    case ActionRegistry.lookup(actions, identifier) do
      {:ok, action} ->
        action

      {:error, _error} ->
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
    if targets != [] and Keyword.keyword?(targets) do
      unsupported_after_target!(targets, env)
    else
      Enum.map(targets, &parse_after_target!(&1, env))
    end
  end

  defp parse_after_targets!(target, env), do: parse_after_target!(target, env)

  defp parse_after_target!(target, _env) when is_atom(target) and not is_nil(target), do: target
  defp parse_after_target!(target, _env) when is_binary(target), do: target

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

  defp unsupported_choice!(statement, env) do
    unsupported!(
      "unsupported flow DSL choice: #{Macro.to_string(statement)}",
      statement,
      env
    )
  end

  defp unsupported_choice_options!(options, env) do
    unsupported!(
      "unsupported flow DSL choice options: #{Macro.to_string(options)}",
      options,
      env
    )
  end

  defp unsupported_choice_condition!(condition, env) do
    unsupported!(
      "unsupported flow DSL choice condition: #{Macro.to_string(condition)}",
      condition,
      env
    )
  end

  defp unsupported_collection_options!(kind, options, env) do
    unsupported!(
      "unsupported flow DSL #{kind} options: #{Macro.to_string(options)}",
      options,
      env
    )
  end

  defp unsupported_loop_options!(options, env) do
    unsupported!(
      "unsupported flow DSL loop options: #{Macro.to_string(options)}",
      options,
      env
    )
  end

  defp unsupported_loop_state!(state, env) do
    unsupported!(
      "unsupported flow DSL loop state: #{Macro.to_string(state)}",
      state,
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
