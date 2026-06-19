defmodule Jido.Flow.Script.Parser do
  @moduledoc false

  alias Jido.Flow

  import Jido.Flow.Script.Parser.AST
  import Jido.Flow.Script.Parser.Support

  @spec from_quoted(Macro.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def from_quoted(quoted) do
    {:ok, parse_quoted!(quoted)}
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  defp parse_quoted!({:flow, meta, args}) do
    {[name_ast], opts_ast, block} = split_call!(args, meta, "flow", 1)
    opts_ast |> eval_keyword!(%{}, meta) |> reject_unknown_opts!([], meta, "flow")

    name = eval_value!(name_ast, %{}, meta)
    state = eval_body!(block, new_state(), %{})

    Flow.new(%{
      name: name,
      inputs: state.inputs,
      flow: state.entries,
      return: state.return
    })
  end

  defp parse_quoted!(other) do
    raise script_error(other, "expected flow name do ... end")
  end

  defp new_state, do: %{entries: [], inputs: [], return: nil}

  defp eval_body!(block, state, vars) do
    block
    |> expressions()
    |> Enum.reduce(state, fn expression, acc -> eval_expression!(expression, acc, vars) end)
  end

  defp eval_expression!({:input, meta, [name_ast]}, state, vars) do
    input = eval_value!(name_ast, vars, meta)

    unless is_atom(input) and not is_nil(input) do
      raise script_error(meta, "input expects an atom name")
    end

    %{state | inputs: Enum.uniq(state.inputs ++ [input])}
  end

  defp eval_expression!({:return, meta, [value_ast]}, state, vars) do
    if not is_nil(state.return) do
      raise script_error(meta, "return can only be declared once")
    end

    %{state | return: eval_reference!(value_ast, vars, meta)}
  end

  defp eval_expression!(expression, state, vars) do
    entries = parse_entries!(expression, vars)
    %{state | entries: state.entries ++ entries}
  end

  defp parse_entries!({:step, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call!(args, meta, "step", 2)
    [name_ast, action_ast] = positionals

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:params, :context, :after], meta, "step")

    block_fields = parse_step_block!(block, vars, meta)

    if Keyword.has_key?(opts, :params) and Map.has_key?(block_fields, :arguments) do
      raise script_error(meta, "step cannot combine params option with argument block")
    end

    params =
      Map.get(block_fields, :arguments) ||
        normalize_params!(Keyword.get(opts, :params, %{}), meta)

    wait_for = Map.get(block_fields, :wait_for)
    after_dep = opts |> Keyword.get(:after) |> normalize_wait_for!(meta)

    [
      %{
        type: :step,
        name: eval_value!(name_ast, vars, meta),
        action: eval_value!(action_ast, vars, meta),
        params: params,
        context: normalize_context!(Keyword.get(opts, :context, %{}), meta),
        after: after_dep || wait_for || dependencies_from_arguments(params)
      }
    ]
  end

  defp parse_entries!({:project, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call!(args, meta, "project", 1)
    [name_ast] = positionals
    reject_block_contents!(block, "project", meta)

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:from, :path, :mode], meta, "project")

    from = opts |> Keyword.get(:from) |> require_atom_name!(meta, "project from")
    path = opts |> Keyword.get(:path) |> validate_path!(meta, "project path")
    mode = Keyword.get(opts, :mode, :value)

    unless mode == :value do
      raise script_error(meta, "project mode must be :value")
    end

    [
      %{
        type: :project,
        name: eval_value!(name_ast, vars, meta),
        from: from,
        path: path,
        mode: mode,
        after: from
      }
    ]
  end

  defp parse_entries!({:map, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call!(args, meta, "map", 2)
    [name_ast, mapper_ast] = positionals

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:source, :over, :after, :inputs, :outputs], meta, "map")

    block_fields = parse_source_block!(block, vars, meta)
    {source, over, after_dep, opts} = parse_source_over!(opts, block_fields, meta, "map")

    [
      %{
        type: :map,
        name: eval_value!(name_ast, vars, meta),
        mapper: eval_callable!(mapper_ast, vars, meta),
        source: source,
        over: over,
        inputs: Keyword.get(opts, :inputs),
        outputs: Keyword.get(opts, :outputs),
        after: after_dep
      }
    ]
  end

  defp parse_entries!({:reduce, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call_any!(args, meta, "reduce", [1, 3])

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:source, :over, :after, :map, :inputs, :outputs], meta, "reduce")

    block_fields = parse_reduce_block!(block, vars, meta)

    {name_ast, init, reducer} =
      parse_reduce_parts!(positionals, block_fields, vars, meta, "reduce")

    {source, over, after_dep, opts} = parse_source_over!(opts, block_fields, meta, "reduce")

    map_opt =
      opts
      |> Keyword.get(:map)
      |> normalize_optional_atom_name!(meta, "reduce map")

    map_name = map_opt || map_from_source(source)

    [
      %{
        type: :reduce,
        name: eval_value!(name_ast, vars, meta),
        init: init,
        reducer: reducer,
        source: source,
        over: over,
        map: map_name,
        inputs: Keyword.get(opts, :inputs),
        outputs: Keyword.get(opts, :outputs),
        after: after_dep
      }
    ]
  end

  defp parse_entries!({:accumulate, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call_any!(args, meta, "accumulate", [1, 3])

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:source, :over, :after, :inputs, :outputs], meta, "accumulate")

    block_fields = parse_reduce_block!(block, vars, meta)

    {name_ast, init, reducer} =
      parse_reduce_parts!(positionals, block_fields, vars, meta, "accumulate")

    {source, over, after_dep, opts} =
      parse_source_over!(opts, block_fields, meta, "accumulate")

    [
      %{
        type: :accumulate,
        name: eval_value!(name_ast, vars, meta),
        init: init,
        reducer: reducer,
        source: source,
        over: over,
        inputs: Keyword.get(opts, :inputs),
        outputs: Keyword.get(opts, :outputs),
        after: after_dep
      }
    ]
  end

  defp parse_entries!({:chain, meta, args}, vars) do
    {[], opts_ast, block} = split_call!(args, meta, "chain", 0)
    opts_ast |> eval_keyword!(vars, meta) |> reject_unknown_opts!([], meta, "chain")

    nested = eval_body!(block, new_state(), vars)
    reject_nested_state!(nested, meta, "chain")
    require_entries!(nested.entries, meta, "chain")

    [%{type: :chain, name: nil, flow: nested.entries, after: nil}]
  end

  defp parse_entries!({:fanout, meta, args}, vars) do
    {[from_ast], opts_ast, block} = split_call!(args, meta, "fanout", 1)
    opts_ast |> eval_keyword!(vars, meta) |> reject_unknown_opts!([], meta, "fanout")

    from = from_ast |> eval_value!(vars, meta) |> require_atom_name!(meta, "fanout source")
    nested = eval_body!(block, new_state(), vars)
    reject_nested_state!(nested, meta, "fanout")
    require_entries!(nested.entries, meta, "fanout")

    [%{type: :fanout, name: nil, from: from, flow: nested.entries, after: from}]
  end

  defp parse_entries!({:collect, meta, args}, vars) do
    {[name_ast], opts_ast, block} = split_call!(args, meta, "collect", 1)
    opts_ast |> eval_keyword!(vars, meta) |> reject_unknown_opts!([], meta, "collect")

    arguments = parse_argument_block!(block, vars, meta)
    require_arguments!(arguments, meta)

    [
      %{
        type: :collect,
        name: eval_value!(name_ast, vars, meta),
        arguments: arguments,
        after: dependencies_from_arguments(arguments)
      }
    ]
  end

  defp parse_entries!({:debug, meta, args}, vars) do
    {[name_ast], opts_ast, block} = split_call!(args, meta, "debug", 1)

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:source, :label, :limit], meta, "debug")

    block_fields = parse_debug_block!(block, vars, meta)
    {source, source_dep} = parse_source_only!(opts, block_fields, meta, "debug")

    label = Map.get(block_fields, :label) || Keyword.get(opts, :label)
    limit = Map.get(block_fields, :limit) || Keyword.get(opts, :limit)
    validate_debug_fields!(label, limit, meta)

    [
      %{
        type: :debug,
        name: eval_value!(name_ast, vars, meta),
        source: source,
        label: label,
        limit: limit,
        after: source_dep
      }
    ]
  end

  defp parse_entries!({:trace, meta, args}, vars) do
    {[name_ast], opts_ast, block} = split_call!(args, meta, "trace", 1)
    reject_block_contents!(block, "trace", meta)

    opts =
      opts_ast
      |> eval_keyword!(vars, meta)
      |> reject_unknown_opts!([:source], meta, "trace")

    source = opts |> Keyword.get(:source) |> normalize_source_ref!(meta)

    [
      %{
        type: :trace,
        name: eval_value!(name_ast, vars, meta),
        source: source,
        after: dependency_from_source(source)
      }
    ]
  end

  defp parse_entries!({:switch, meta, args}, vars) do
    {[name_ast], opts_ast, block} = split_call!(args, meta, "switch", 1)

    switch =
      case block do
        nil ->
          parse_compact_switch!(opts_ast, vars, meta)

        block ->
          opts_ast |> eval_keyword!(vars, meta) |> reject_unknown_opts!([], meta, "switch")
          parse_switch_block!(block, vars, meta)
      end
      |> validate_switch!(meta)

    [
      Map.merge(
        %{
          type: :switch,
          name: eval_value!(name_ast, vars, meta),
          after: dependency_from_source(switch.on)
        },
        switch
      )
    ]
  end

  defp parse_entries!(other, _vars) do
    raise script_error(other, "unsupported flow script expression")
  end

  defp parse_source_over!(opts, block_fields, meta, form) do
    {source_opt, opts} = Keyword.pop(opts, :source)
    {over_opt, opts} = Keyword.pop(opts, :over)
    block_source = Map.get(block_fields, :source)

    reject_source_conflict!(source_opt, over_opt, block_source, meta, form)

    over = normalize_over!(over_opt, meta)
    source = block_source || normalize_source_ref!(source_opt, meta)
    explicit_after = opts |> Keyword.get(:after) |> normalize_wait_for!(meta)
    after_dep = explicit_after || dependency_from_source(source) || dependency_from_over(over)

    {source, over, after_dep, opts}
  end

  defp parse_source_only!(opts, block_fields, meta, form) do
    source_opt = Keyword.get(opts, :source)
    block_source = Map.get(block_fields, :source)

    reject_source_conflict!(source_opt, nil, block_source, meta, form)

    source = block_source || normalize_source_ref!(source_opt, meta)
    {source, dependency_from_source(source)}
  end

  defp parse_reduce_parts!(positionals, block_fields, vars, meta, form) do
    case positionals do
      [name_ast, init_ast, reducer_ast] ->
        {name_ast, eval_value!(init_ast, vars, meta), eval_callable!(reducer_ast, vars, meta)}

      [name_ast] ->
        require_reduce_block!(block_fields, meta, form)
        {name_ast, Map.fetch!(block_fields, :init), Map.fetch!(block_fields, :reducer)}

      _other ->
        raise script_error(meta, "#{form} expects 1 or 3 positional arguments")
    end
  end

  defp parse_step_block!(nil, _vars, _meta), do: %{}

  defp parse_step_block!(block, vars, meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:argument, arg_meta, [name_ast, value_ast]}, acc ->
        arguments = Map.get(acc, :arguments, %{})

        name =
          name_ast |> eval_value!(vars, arg_meta) |> require_atom_name!(arg_meta, "argument name")

        value = eval_reference!(value_ast, vars, arg_meta)

        Map.put(acc, :arguments, put_argument!(arguments, name, value, arg_meta))

      {:wait_for, wait_meta, [dependency_ast]}, acc ->
        if Map.has_key?(acc, :wait_for) do
          raise script_error(wait_meta, "wait_for can only be declared once")
        end

        dependency = eval_value!(dependency_ast, vars, wait_meta)
        Map.put(acc, :wait_for, normalize_wait_for!(dependency, wait_meta))

      other, _acc ->
        raise script_error(other, "unsupported step block expression")
    end)
  rescue
    error in [KeyError] -> raise script_error(meta, Exception.message(error))
  end

  defp parse_argument_block!(block, vars, _meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:argument, arg_meta, [name_ast, value_ast]}, acc ->
        name =
          name_ast |> eval_value!(vars, arg_meta) |> require_atom_name!(arg_meta, "argument name")

        value = eval_reference!(value_ast, vars, arg_meta)

        put_argument!(acc, name, value, arg_meta)

      other, _acc ->
        raise script_error(other, "unsupported collect block expression")
    end)
  end

  defp parse_source_block!(nil, _vars, _meta), do: %{}

  defp parse_source_block!(block, vars, _meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:source, source_meta, [source_ast]}, acc ->
        put_block_field!(
          acc,
          :source,
          eval_reference!(source_ast, vars, source_meta),
          source_meta,
          "source"
        )

      other, _acc ->
        raise script_error(other, "unsupported source block expression")
    end)
  end

  defp parse_reduce_block!(nil, _vars, _meta), do: %{}

  defp parse_reduce_block!(block, vars, _meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:source, source_meta, [source_ast]}, acc ->
        put_block_field!(
          acc,
          :source,
          eval_reference!(source_ast, vars, source_meta),
          source_meta,
          "source"
        )

      {:init, init_meta, [init_ast]}, acc ->
        put_block_field!(acc, :init, eval_value!(init_ast, vars, init_meta), init_meta, "init")

      {:run, run_meta, [callable_ast]}, acc ->
        put_block_field!(
          acc,
          :reducer,
          eval_callable!(callable_ast, vars, run_meta),
          run_meta,
          "run"
        )

      other, _acc ->
        raise script_error(other, "unsupported primitive block expression")
    end)
  end

  defp parse_debug_block!(nil, _vars, _meta), do: %{}

  defp parse_debug_block!(block, vars, _meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:source, source_meta, [source_ast]}, acc ->
        put_block_field!(
          acc,
          :source,
          eval_reference!(source_ast, vars, source_meta),
          source_meta,
          "source"
        )

      {:label, label_meta, [label_ast]}, acc ->
        put_block_field!(
          acc,
          :label,
          eval_value!(label_ast, vars, label_meta),
          label_meta,
          "label"
        )

      {:limit, limit_meta, [limit_ast]}, acc ->
        put_block_field!(
          acc,
          :limit,
          eval_value!(limit_ast, vars, limit_meta),
          limit_meta,
          "limit"
        )

      other, _acc ->
        raise script_error(other, "unsupported debug block expression")
    end)
  end

  defp parse_compact_switch!(opts_ast, vars, meta) do
    opts = eval_switch_keyword!(opts_ast, vars, meta)

    unless Keyword.has_key?(opts, :on) do
      raise script_error(meta, "switch expects an :on option")
    end

    %{
      on: Keyword.get(opts, :on),
      matches: Keyword.get(opts, :matches?, []),
      default: Keyword.get(opts, :default),
      return?: Keyword.get(opts, :return, false)
    }
  end

  defp parse_switch_block!(block, vars, _meta) do
    block
    |> expressions()
    |> Enum.reduce(%{on: nil, matches: [], default: nil, return?: false}, fn
      {:on, on_meta, [on_ast]}, acc ->
        if not is_nil(acc.on) do
          raise script_error(on_meta, "switch accepts on/1 only once")
        end

        %{acc | on: eval_reference!(on_ast, vars, on_meta)}

      {:matches?, match_meta, args}, acc ->
        {positionals, opts_ast, match_block} = split_call!(args, match_meta, "matches?", 2)

        opts_ast
        |> eval_keyword!(vars, match_meta)
        |> reject_unknown_opts!([], match_meta, "matches?")

        [name_ast, predicate_ast] = positionals
        nested = eval_body!(match_block, new_state(), vars)
        reject_nested_inputs!(nested, match_meta, "switch match")

        if nested.entries == [] and is_nil(nested.return) do
          raise script_error(match_meta, "switch match cannot be empty")
        end

        match = %{
          name: eval_value!(name_ast, vars, match_meta),
          predicate: eval_callable!(predicate_ast, vars, match_meta),
          flow: nested.entries,
          return: nested.return
        }

        %{acc | matches: acc.matches ++ [match]}

      {:default, default_meta, args}, acc ->
        if not is_nil(acc.default) do
          raise script_error(default_meta, "switch accepts default only once")
        end

        {[], opts_ast, default_block} = split_call!(args, default_meta, "default", 0)

        opts_ast
        |> eval_keyword!(vars, default_meta)
        |> reject_unknown_opts!([], default_meta, "default")

        nested = eval_body!(default_block, new_state(), vars)
        reject_nested_inputs!(nested, default_meta, "switch default")

        if nested.entries == [] and is_nil(nested.return) do
          raise script_error(default_meta, "switch default cannot be empty")
        end

        %{acc | default: %{flow: nested.entries, return: nested.return}}

      other, _acc ->
        raise script_error(other, "unsupported switch block expression")
    end)
  end

  defp eval_switch_keyword!(values, vars, meta) when is_list(values) do
    unless Keyword.keyword?(values), do: raise(script_error(meta, "expected keyword options"))
    reject_duplicate_opts!(values, meta, "switch")

    Enum.map(values, fn
      {:on, value} ->
        {:on, eval_reference!(value, vars, meta)}

      {:matches?, matches} ->
        {:matches?, eval_switch_matches!(matches, vars, meta)}

      {:default, value} ->
        {:default, eval_value!(value, vars, meta)}

      {:return, value} ->
        {:return, eval_value!(value, vars, meta)}

      {key, _value} ->
        raise script_error(meta, "unsupported switch option #{inspect(key)}")
    end)
  end

  defp eval_switch_keyword!(_values, _vars, meta),
    do: raise(script_error(meta, "expected keyword options"))

  defp eval_switch_matches!(matches, vars, meta) when is_list(matches) do
    unless Keyword.keyword?(matches),
      do: raise(script_error(meta, "matches? expects a keyword list"))

    Enum.map(matches, fn {name, value} ->
      case value do
        {predicate_ast, target_ast} ->
          %{
            name: name,
            predicate: eval_callable!(predicate_ast, vars, meta),
            then: eval_value!(target_ast, vars, meta)
          }

        _other ->
          raise script_error(meta, "switch match values must be {predicate, target} tuples")
      end
    end)
  end

  defp eval_switch_matches!(_matches, _vars, meta),
    do: raise(script_error(meta, "matches? expects a keyword list"))
end
