defmodule Jido.Flow.Script do
  @moduledoc """
  Restricted Elixir-term scripting for building `Jido.Flow` values.

  The script source is parsed with `Code.string_to_quoted/2`, then interpreted
  against a small allow-list of Flow-building forms. This is intentionally not a
  general Elixir evaluator.
  """

  alias Jido.Flow

  @type option :: {:allowed_atoms, [atom()]}

  @doc """
  Parses a Flow script string into a `Jido.Flow`.

  Script atom parsing is hardened with a static atom encoder. Atoms must either
  already exist in the VM or be supplied through `:allowed_atoms`.
  """
  @spec parse(String.t(), [option()]) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def parse(source, opts \\ []) when is_binary(source) and is_list(opts) do
    with {:ok, quoted} <- string_to_quoted(source, opts),
         {:ok, flow} <- from_quoted(quoted) do
      {:ok, flow}
    end
  end

  @doc """
  Parses a Flow script string into a `Jido.Flow`, raising on errors.
  """
  @spec parse!(String.t(), [option()]) :: Flow.t()
  def parse!(source, opts \\ []) when is_binary(source) and is_list(opts) do
    case parse(source, opts) do
      {:ok, flow} -> flow
      {:error, error} -> raise error
    end
  end

  @doc """
  Parses a Flow script file into a `Jido.Flow`, raising on errors.
  """
  @spec parse_file!(Path.t(), [option()]) :: Flow.t()
  def parse_file!(path, opts \\ []) when is_list(opts) do
    path
    |> File.read!()
    |> parse!(opts)
  end

  @doc """
  Projects Flow IR back to normalized script syntax.

  Formatting and comments are not preserved. Semantic IR shape is preserved for
  supported script forms.
  """
  @spec to_script(Flow.t()) :: String.t()
  def to_script(%Flow{} = flow) do
    flow = Flow.new(Flow.to_map(flow))

    body =
      []
      |> Kernel.++(Enum.map(flow.inputs, &line("input(#{atom(&1)})")))
      |> append_blank_if_needed(
        flow.inputs != [] and (flow.flow != [] or not is_nil(flow.return))
      )
      |> Kernel.++(Enum.flat_map(flow.flow, &entry_to_lines(&1, 1)))
      |> append_blank_if_needed(flow.flow != [] and not is_nil(flow.return))
      |> maybe_append_return(flow.return, 1)

    ["flow #{atom(flow.name)} do", indent_lines(body, 1), "end"]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc false
  @spec from_quoted(Macro.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def from_quoted(quoted) do
    {:ok, parse_quoted!(quoted)}
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  defp string_to_quoted(source, opts) do
    allowed_atoms = Keyword.get(opts, :allowed_atoms, [])
    atom_encoder = atom_encoder(allowed_atoms)

    case Code.string_to_quoted(source, columns: true, static_atoms_encoder: atom_encoder) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, {_location, message, token}} ->
        {:error, ArgumentError.exception("invalid flow script: #{message}#{token}")}
    end
  end

  defp atom_encoder(allowed_atoms) do
    allowed =
      allowed_atoms
      |> Enum.map(fn
        atom when is_atom(atom) ->
          {Atom.to_string(atom), atom}

        other ->
          raise ArgumentError, "allowed_atoms must contain only atoms, got: #{inspect(other)}"
      end)
      |> Map.new()

    fn atom_string, _meta ->
      case Map.fetch(allowed, atom_string) do
        {:ok, atom} -> {:ok, atom}
        :error -> existing_atom(atom_string)
      end
    end
  end

  defp existing_atom(atom_string) do
    {:ok, String.to_existing_atom(atom_string)}
  rescue
    ArgumentError -> {:error, "unsafe atom does not exist: "}
  end

  defp parse_quoted!({:flow, meta, args}) do
    {[name_ast], _opts, block} = split_call!(args, meta, "flow", 1)
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
    %{state | return: eval_reference!(value_ast, vars, meta)}
  end

  defp eval_expression!({:loop, meta, args}, state, vars) do
    {[pattern], opts_ast, block} = split_call!(args, meta, "loop", 1)
    opts = eval_keyword!(opts_ast, vars, meta)
    enumerable = Keyword.get(opts, :in)

    unless Enumerable.impl_for(enumerable) do
      raise script_error(meta, "loop expects an enumerable :in option")
    end

    Enum.reduce(enumerable, state, fn value, acc ->
      loop_vars = bind_pattern!(pattern, value, vars, meta)
      eval_body!(block, acc, loop_vars)
    end)
  end

  defp eval_expression!(expression, state, vars) do
    entries = parse_entries!(expression, vars)
    %{state | entries: state.entries ++ entries}
  end

  defp parse_entries!({:step, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call!(args, meta, "step", 2)
    [name_ast, action_ast] = positionals
    opts = eval_keyword!(opts_ast, vars, meta)
    block_fields = parse_step_block!(block, vars, meta)

    params =
      Map.get(block_fields, :arguments) ||
        normalize_params!(Keyword.get(opts, :params, %{}), meta)

    wait_for = Map.get(block_fields, :wait_for)

    [
      %{
        type: :step,
        name: eval_value!(name_ast, vars, meta),
        action: eval_value!(action_ast, vars, meta),
        params: params,
        context: normalize_context!(Keyword.get(opts, :context, %{}), meta),
        after: Keyword.get(opts, :after) || wait_for || dependencies_from_arguments(params)
      }
    ]
  end

  defp parse_entries!({:project, meta, args}, vars) do
    {positionals, opts_ast, nil} = split_call!(args, meta, "project", 1)
    [name_ast] = positionals
    opts = eval_keyword!(opts_ast, vars, meta)

    [
      %{
        type: :project,
        name: eval_value!(name_ast, vars, meta),
        from: Keyword.get(opts, :from),
        path: Keyword.get(opts, :path),
        mode: Keyword.get(opts, :mode, :value),
        after: Keyword.get(opts, :from)
      }
    ]
  end

  defp parse_entries!({:map, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call!(args, meta, "map", 2)
    [name_ast, mapper_ast] = positionals
    opts = eval_keyword!(opts_ast, vars, meta)
    {source, opts} = Keyword.pop(opts, :source)
    {over, opts} = Keyword.pop(opts, :over)
    block_fields = parse_source_block!(block, vars, meta)
    source = Map.get(block_fields, :source) || source || source_from_over(over)

    {project_entries, source, after_dep} =
      lower_over!(over, source, Keyword.get(opts, :after), vars, meta)

    project_entries ++
      [
        %{
          type: :map,
          name: eval_value!(name_ast, vars, meta),
          mapper: eval_callable!(mapper_ast, vars, meta),
          source: source,
          inputs: Keyword.get(opts, :inputs),
          outputs: Keyword.get(opts, :outputs),
          after: after_dep || dependency_from_source(source)
        }
      ]
  end

  defp parse_entries!({:reduce, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call_any!(args, meta, "reduce", [1, 3])
    opts = eval_keyword!(opts_ast, vars, meta)
    block_fields = parse_reduce_block!(block, vars, meta)

    {name_ast, init, reducer} =
      case positionals do
        [name_ast, init_ast, reducer_ast] ->
          {name_ast, eval_value!(init_ast, vars, meta), eval_callable!(reducer_ast, vars, meta)}

        [name_ast] ->
          {name_ast, Map.fetch!(block_fields, :init), Map.fetch!(block_fields, :reducer)}

        _other ->
          raise script_error(meta, "reduce expects 1 or 3 positional arguments")
      end

    {source, opts} = Keyword.pop(opts, :source)
    {over, opts} = Keyword.pop(opts, :over)
    source = Map.get(block_fields, :source) || source || source_from_over(over)

    {project_entries, source, after_dep} =
      lower_over!(over, source, Keyword.get(opts, :after), vars, meta)

    map_name = Keyword.get(opts, :map) || map_from_source(source)

    project_entries ++
      [
        %{
          type: :reduce,
          name: eval_value!(name_ast, vars, meta),
          init: init,
          reducer: reducer,
          source: source,
          map: map_name,
          inputs: Keyword.get(opts, :inputs),
          outputs: Keyword.get(opts, :outputs),
          after: after_dep || dependency_from_source(source)
        }
      ]
  end

  defp parse_entries!({:accumulate, meta, args}, vars) do
    {positionals, opts_ast, block} = split_call_any!(args, meta, "accumulate", [1, 3])
    opts = eval_keyword!(opts_ast, vars, meta)
    block_fields = parse_reduce_block!(block, vars, meta)

    {name_ast, init, reducer} =
      case positionals do
        [name_ast, init_ast, reducer_ast] ->
          {name_ast, eval_value!(init_ast, vars, meta), eval_callable!(reducer_ast, vars, meta)}

        [name_ast] ->
          {name_ast, Map.fetch!(block_fields, :init), Map.fetch!(block_fields, :reducer)}

        _other ->
          raise script_error(meta, "accumulate expects 1 or 3 positional arguments")
      end

    {source, opts} = Keyword.pop(opts, :source)
    {over, opts} = Keyword.pop(opts, :over)
    source = Map.get(block_fields, :source) || source || source_from_over(over)

    {project_entries, source, after_dep} =
      lower_over!(over, source, Keyword.get(opts, :after), vars, meta)

    project_entries ++
      [
        %{
          type: :accumulate,
          name: eval_value!(name_ast, vars, meta),
          init: init,
          reducer: reducer,
          source: source,
          inputs: Keyword.get(opts, :inputs),
          outputs: Keyword.get(opts, :outputs),
          after: after_dep || dependency_from_source(source)
        }
      ]
  end

  defp parse_entries!({:chain, meta, args}, vars) do
    {[], _opts_ast, block} = split_call!(args, meta, "chain", 0)
    nested = eval_body!(block, new_state(), vars)
    [%{type: :chain, name: nil, flow: nested.entries, after: nil}]
  end

  defp parse_entries!({:fanout, meta, args}, vars) do
    {[from_ast], _opts_ast, block} = split_call!(args, meta, "fanout", 1)
    from = eval_value!(from_ast, vars, meta)
    nested = eval_body!(block, new_state(), vars)
    [%{type: :fanout, name: nil, from: from, flow: nested.entries, after: from}]
  end

  defp parse_entries!({:collect, meta, args}, vars) do
    {[name_ast], _opts_ast, block} = split_call!(args, meta, "collect", 1)
    arguments = parse_argument_block!(block, vars, meta)

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
    opts = eval_keyword!(opts_ast, vars, meta)
    block_fields = parse_debug_block!(block, vars, meta)
    source = Map.get(block_fields, :source) || Keyword.get(opts, :source)

    [
      %{
        type: :debug,
        name: eval_value!(name_ast, vars, meta),
        source: source,
        label: Map.get(block_fields, :label) || Keyword.get(opts, :label),
        limit: Map.get(block_fields, :limit) || Keyword.get(opts, :limit),
        after: dependency_from_source(source)
      }
    ]
  end

  defp parse_entries!({:trace, meta, args}, vars) do
    {[name_ast], opts_ast, nil} = split_call!(args, meta, "trace", 1)
    opts = eval_keyword!(opts_ast, vars, meta)
    source = Keyword.get(opts, :source)

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
        nil -> parse_compact_switch!(opts_ast, vars, meta)
        block -> parse_switch_block!(block, vars, meta)
      end

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

  defp parse_step_block!(nil, _vars, _meta), do: %{}

  defp parse_step_block!(block, vars, meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:argument, arg_meta, [name_ast, value_ast]}, acc ->
        arguments = Map.get(acc, :arguments, %{})

        Map.put(
          acc,
          :arguments,
          Map.put(
            arguments,
            eval_value!(name_ast, vars, arg_meta),
            eval_reference!(value_ast, vars, arg_meta)
          )
        )

      {:wait_for, wait_meta, [dependency_ast]}, acc ->
        dependency = eval_value!(dependency_ast, vars, wait_meta)
        Map.put(acc, :wait_for, normalize_wait_for!(dependency, wait_meta))

      other, _acc ->
        raise script_error(other, "unsupported step block expression")
    end)
    |> ensure_block_arguments_map()
  rescue
    error in [KeyError] -> raise script_error(meta, Exception.message(error))
  end

  defp parse_argument_block!(block, vars, _meta) do
    block
    |> expressions()
    |> Enum.reduce(%{}, fn
      {:argument, arg_meta, [name_ast, value_ast]}, acc ->
        Map.put(
          acc,
          eval_value!(name_ast, vars, arg_meta),
          eval_reference!(value_ast, vars, arg_meta)
        )

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
        Map.put(acc, :source, eval_reference!(source_ast, vars, source_meta))

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
        Map.put(acc, :source, eval_reference!(source_ast, vars, source_meta))

      {:init, init_meta, [init_ast]}, acc ->
        Map.put(acc, :init, eval_value!(init_ast, vars, init_meta))

      {:run, run_meta, [callable_ast]}, acc ->
        Map.put(acc, :reducer, eval_callable!(callable_ast, vars, run_meta))

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
        Map.put(acc, :source, eval_reference!(source_ast, vars, source_meta))

      {:label, label_meta, [label_ast]}, acc ->
        Map.put(acc, :label, eval_value!(label_ast, vars, label_meta))

      {:limit, limit_meta, [limit_ast]}, acc ->
        Map.put(acc, :limit, eval_value!(limit_ast, vars, limit_meta))

      other, _acc ->
        raise script_error(other, "unsupported debug block expression")
    end)
  end

  defp parse_compact_switch!(opts_ast, vars, meta) do
    opts = eval_switch_keyword!(opts_ast, vars, meta)

    %{
      on: Keyword.fetch!(opts, :on),
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
        %{acc | on: eval_reference!(on_ast, vars, on_meta)}

      {:matches?, match_meta, args}, acc ->
        {positionals, _opts_ast, match_block} = split_call!(args, match_meta, "matches?", 2)
        [name_ast, predicate_ast] = positionals
        nested = eval_body!(match_block, new_state(), vars)

        match = %{
          name: eval_value!(name_ast, vars, match_meta),
          predicate: eval_callable!(predicate_ast, vars, match_meta),
          flow: nested.entries,
          return: nested.return
        }

        %{acc | matches: acc.matches ++ [match]}

      {:default, default_meta, args}, acc ->
        {[], _opts_ast, default_block} = split_call!(args, default_meta, "default", 0)
        nested = eval_body!(default_block, new_state(), vars)
        %{acc | default: %{flow: nested.entries, return: nested.return}}

      other, _acc ->
        raise script_error(other, "unsupported switch block expression")
    end)
  end

  defp eval_switch_keyword!(values, vars, meta) when is_list(values) do
    unless Keyword.keyword?(values), do: raise(script_error(meta, "expected keyword options"))

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

  defp eval_reference!({:input, meta, [name_ast]}, vars, _parent_meta) do
    name = eval_value!(name_ast, vars, meta)

    unless is_atom(name) and not is_nil(name) do
      raise script_error(meta, "input reference expects an atom name")
    end

    {:input, name}
  end

  defp eval_reference!({:result, meta, [name_ast]}, vars, _parent_meta) do
    name = eval_value!(name_ast, vars, meta)

    unless is_atom(name) and not is_nil(name) do
      raise script_error(meta, "result reference expects an atom name")
    end

    {:result, name}
  end

  defp eval_reference!({:result, meta, [name_ast, path_ast]}, vars, _parent_meta) do
    name = eval_value!(name_ast, vars, meta)
    path = eval_value!(path_ast, vars, meta)

    unless is_atom(name) and not is_nil(name) do
      raise script_error(meta, "result reference expects an atom name")
    end

    {:result, name, path}
  end

  defp eval_reference!({:value, meta, [value_ast]}, vars, _parent_meta),
    do: {:value, eval_value!(value_ast, vars, meta)}

  defp eval_reference!({:element, meta, [name_ast]}, vars, _parent_meta),
    do: {:element, eval_value!(name_ast, vars, meta)}

  defp eval_reference!(value, vars, meta) when is_atom(value) and not is_nil(value),
    do: {:result, eval_value!(value, vars, meta)}

  defp eval_reference!(other, _vars, _meta) do
    raise script_error(other, "expected input/1, result/1, result/2, value/1, or element/1")
  end

  defp eval_value!(value, _vars, _meta)
       when is_atom(value) or is_binary(value) or is_integer(value) or is_float(value),
       do: value

  defp eval_value!({:__aliases__, meta, parts}, _vars, _parent_meta) do
    Module.safe_concat(parts)
  rescue
    ArgumentError ->
      raise script_error(meta, "module #{Enum.join(parts, ".")} is not loaded")
  end

  defp eval_value!({:%{}, meta, pairs}, vars, _parent_meta) do
    Map.new(pairs, fn
      {key, value} -> {eval_value!(key, vars, meta), eval_option_value!(value, vars, meta)}
      other -> raise script_error(other, "invalid map entry")
    end)
  end

  defp eval_value!({:{}, meta, values}, vars, _parent_meta) when is_list(values) do
    values
    |> Enum.map(&eval_option_value!(&1, vars, meta))
    |> List.to_tuple()
  end

  defp eval_value!({left, right}, vars, meta) do
    {eval_option_value!(left, vars, meta), eval_option_value!(right, vars, meta)}
  end

  defp eval_value!({name, meta, nil}, vars, _parent_meta) when is_atom(name) do
    case Map.fetch(vars, name) do
      {:ok, value} -> value
      :error -> raise script_error(meta, "unbound script variable #{inspect(name)}")
    end
  end

  defp eval_value!(values, vars, meta) when is_list(values) do
    if Keyword.keyword?(values) do
      eval_keyword!(values, vars, meta)
    else
      Enum.map(values, &eval_option_value!(&1, vars, meta))
    end
  end

  defp eval_value!(other, _vars, _meta) do
    raise script_error(other, "unsupported script value")
  end

  defp eval_option_value!(ast, vars, meta) do
    cond do
      reference_ast?(ast) -> eval_reference!(ast, vars, meta)
      callable_ast?(ast) -> eval_callable!(ast, vars, meta)
      true -> eval_value!(ast, vars, meta)
    end
  end

  defp eval_callable!({:&, meta, [{:/, _div_meta, [call_ast, arity]}]}, _vars, _parent_meta)
       when is_integer(arity) do
    case call_ast do
      {{:., _dot_meta, [module_ast, function]}, _call_meta, []} when is_atom(function) ->
        module = eval_value!(module_ast, %{}, meta)

        unless Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
          raise script_error(
                  meta,
                  "callable #{inspect(module)}.#{function}/#{arity} is not exported"
                )
        end

        {module, function}

      _other ->
        raise script_error(meta, "unsupported external function capture")
    end
  end

  defp eval_callable!(ast, vars, meta), do: eval_value!(ast, vars, meta)

  defp eval_keyword!(values, vars, meta) when is_list(values) do
    if Keyword.keyword?(values) do
      Enum.map(values, fn {key, value} -> {key, eval_option_value!(value, vars, meta)} end)
    else
      raise script_error(meta, "expected keyword options")
    end
  end

  defp eval_keyword!(other, _vars, _meta) do
    raise script_error(other, "expected keyword options")
  end

  defp normalize_params!(value, _meta) when is_map(value), do: value

  defp normalize_params!(value, meta) when is_list(value) do
    if Keyword.keyword?(value),
      do: Map.new(value),
      else: raise(script_error(meta, "params must be a map"))
  end

  defp normalize_params!(_value, meta), do: raise(script_error(meta, "params must be a map"))

  defp normalize_context!(value, _meta) when is_map(value), do: value

  defp normalize_context!(value, meta) when is_list(value) do
    if Keyword.keyword?(value),
      do: Map.new(value),
      else: raise(script_error(meta, "context must be a map"))
  end

  defp normalize_context!(_value, meta), do: raise(script_error(meta, "context must be a map"))

  defp normalize_wait_for!(nil, _meta), do: nil

  defp normalize_wait_for!(values, meta) when is_list(values) do
    cond do
      values == [] -> raise script_error(meta, "wait_for cannot be empty")
      Enum.all?(values, &is_atom/1) -> values
      true -> raise script_error(meta, "wait_for expects atom names")
    end
  end

  defp normalize_wait_for!(value, _meta) when is_atom(value), do: value

  defp normalize_wait_for!(_value, meta),
    do: raise(script_error(meta, "wait_for expects atom names"))

  defp ensure_block_arguments_map(%{arguments: arguments} = fields) when is_map(arguments),
    do: fields

  defp ensure_block_arguments_map(fields), do: fields

  defp lower_over!(nil, source, after_dep, _vars, _meta), do: {[], source, after_dep}

  defp lower_over!(over, source, after_dep, _vars, _meta) when is_atom(over) do
    {[], source || {:result, over}, after_dep || over}
  end

  defp lower_over!({name, opts}, source, after_dep, _vars, meta)
       when is_atom(name) and is_list(opts) do
    from = Keyword.get(opts, :from)
    path = Keyword.get(opts, :path)

    unless is_atom(from) and is_list(path) do
      raise script_error(meta, "over path source expects {:name, from: :source, path: [...]}")
    end

    project = %{type: :project, name: name, from: from, path: path, mode: :value, after: from}
    {[project], source || {:result, name}, after_dep || name}
  end

  defp lower_over!(_over, _source, _after_dep, _vars, meta) do
    raise script_error(meta, "over expects an atom or {:name, from: :source, path: [...]}")
  end

  defp source_from_over(nil), do: nil
  defp source_from_over(name) when is_atom(name), do: {:result, name}
  defp source_from_over({name, opts}) when is_atom(name) and is_list(opts), do: {:result, name}
  defp source_from_over(_other), do: nil

  defp dependency_from_source({:result, name}) when is_atom(name), do: name
  defp dependency_from_source({:result, name, _path}) when is_atom(name), do: name
  defp dependency_from_source(_source), do: nil

  defp dependencies_from_arguments(arguments) do
    arguments
    |> Map.values()
    |> Enum.flat_map(fn
      {:result, name} -> [name]
      {:result, name, _path} -> [name]
      _other -> []
    end)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [name] -> name
      names -> names
    end
  end

  defp map_from_source({:result, name}) when is_atom(name), do: name
  defp map_from_source(_source), do: nil

  defp bind_pattern!({name, _meta, nil}, value, vars, _parent_meta) when is_atom(name),
    do: Map.put(vars, name, value)

  defp bind_pattern!({left_pattern, right_pattern}, {left, right}, vars, meta) do
    vars = bind_pattern!(left_pattern, left, vars, meta)
    bind_pattern!(right_pattern, right, vars, meta)
  end

  defp bind_pattern!({:{}, _tuple_meta, patterns}, value, vars, meta)
       when is_tuple(value) and tuple_size(value) == length(patterns) do
    patterns
    |> Enum.zip(Tuple.to_list(value))
    |> Enum.reduce(vars, fn {pattern, part}, acc -> bind_pattern!(pattern, part, acc, meta) end)
  end

  defp bind_pattern!(literal, literal, vars, _meta)
       when is_atom(literal) or is_binary(literal) or is_integer(literal) or is_float(literal),
       do: vars

  defp bind_pattern!(pattern, value, _vars, meta) do
    raise script_error(meta, "loop pattern #{inspect(pattern)} does not match #{inspect(value)}")
  end

  defp split_call!(args, meta, name, positional_count) do
    {args, block} = pop_do_block(args)
    {positionals, opts} = pop_options(args)

    unless length(positionals) == positional_count do
      raise script_error(meta, "#{name} expects #{positional_count} positional arguments")
    end

    {positionals, opts, block}
  end

  defp split_call_any!(args, meta, name, positional_counts) do
    {args, block} = pop_do_block(args)
    {positionals, opts} = pop_options(args)

    unless length(positionals) in positional_counts do
      raise script_error(
              meta,
              "#{name} expects #{Enum.map_join(positional_counts, " or ", &to_string/1)} positional arguments"
            )
    end

    {positionals, opts, block}
  end

  defp pop_do_block(args) do
    case List.last(args) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts) do
          {block, opts} = Keyword.pop(opts, :do)
          args = if opts == [], do: Enum.drop(args, -1), else: List.replace_at(args, -1, opts)
          {args, block}
        else
          {args, nil}
        end

      _other ->
        {args, nil}
    end
  end

  defp pop_options(args) do
    case List.last(args) do
      opts when is_list(opts) ->
        if Keyword.keyword?(opts), do: {Enum.drop(args, -1), opts}, else: {args, []}

      _other ->
        {args, []}
    end
  end

  defp expressions({:__block__, _meta, expressions}), do: expressions
  defp expressions(nil), do: []
  defp expressions(expression), do: [expression]

  defp reference_ast?({name, _meta, _args}) when name in [:input, :result, :value, :element],
    do: true

  defp reference_ast?(_ast), do: false

  defp callable_ast?({:&, _meta, _args}), do: true
  defp callable_ast?(_ast), do: false

  defp maybe_append_return(lines, nil, _level), do: lines

  defp maybe_append_return(lines, return_ref, _level),
    do: lines ++ [line("return(#{ref(return_ref)})")]

  defp append_blank_if_needed(lines, true), do: lines ++ [""]
  defp append_blank_if_needed(lines, false), do: lines

  defp entry_to_lines(%{type: :step} = entry, level) do
    params = Map.get(entry, :params, %{})

    if Enum.any?(params, fn {_key, value} -> reference?(value) end) do
      block =
        params
        |> Enum.map(fn {key, value} -> line("argument(#{atom(key)}, #{ref(value)})") end)
        |> maybe_append_wait_for(Map.get(entry, :after))

      block_entry("step #{atom(entry.name)}, #{module(entry.action)}", block, level)
    else
      opts = []
      opts = if params == %{}, do: opts, else: opts ++ ["params: #{value(params)}"]
      opts = if entry.context == %{}, do: opts, else: opts ++ ["context: #{value(entry.context)}"]
      opts = if entry.after, do: opts ++ ["after: #{value(entry.after)}"], else: opts
      [line("step #{atom(entry.name)}, #{module(entry.action)}#{opts_suffix(opts)}")]
    end
  end

  defp entry_to_lines(%{type: :project} = entry, _level) do
    [
      line(
        "project #{atom(entry.name)}, from: #{atom(entry.from)}, path: #{value(entry.path)}#{mode_suffix(entry.mode)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :map, source: source} = entry, level) when not is_nil(source) do
    block_entry(
      "map #{atom(entry.name)}, #{callable(entry.mapper)}",
      [line("source(#{ref(source)})")],
      level
    )
  end

  defp entry_to_lines(%{type: :map} = entry, _level) do
    opts = primitive_opts(entry, [])
    [line("map #{atom(entry.name)}, #{callable(entry.mapper)}#{opts_suffix(opts)}")]
  end

  defp entry_to_lines(%{type: :reduce, source: source} = entry, level) when not is_nil(source) do
    block_entry(
      "reduce #{atom(entry.name)}",
      [
        line("source(#{ref(source)})"),
        line("init(#{value(entry.init)})"),
        line("run(#{callable(entry.reducer)})")
      ],
      level
    )
  end

  defp entry_to_lines(%{type: :reduce} = entry, _level) do
    opts = primitive_opts(entry, map_opt(entry))

    [
      line(
        "reduce #{atom(entry.name)}, #{value(entry.init)}, #{callable(entry.reducer)}#{opts_suffix(opts)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :accumulate, source: source} = entry, level)
       when not is_nil(source) do
    block_entry(
      "accumulate #{atom(entry.name)}",
      [
        line("source(#{ref(source)})"),
        line("init(#{value(entry.init)})"),
        line("run(#{callable(entry.reducer)})")
      ],
      level
    )
  end

  defp entry_to_lines(%{type: :accumulate} = entry, _level) do
    opts = primitive_opts(entry, [])

    [
      line(
        "accumulate #{atom(entry.name)}, #{value(entry.init)}, #{callable(entry.reducer)}#{opts_suffix(opts)}"
      )
    ]
  end

  defp entry_to_lines(%{type: :chain} = entry, level) do
    block_entry("chain", Enum.flat_map(entry.flow, &entry_to_lines(&1, level + 1)), level)
  end

  defp entry_to_lines(%{type: :fanout} = entry, level) do
    block_entry(
      "fanout #{atom(entry.from)}",
      Enum.flat_map(entry.flow, &entry_to_lines(&1, level + 1)),
      level
    )
  end

  defp entry_to_lines(%{type: :collect} = entry, level) do
    block =
      Enum.map(entry.arguments, fn {key, value} ->
        line("argument(#{atom(key)}, #{ref(value)})")
      end)

    block_entry("collect #{atom(entry.name)}", block, level)
  end

  defp entry_to_lines(%{type: :debug} = entry, level) do
    block =
      []
      |> maybe_append_source(entry.source)
      |> maybe_append_field(:label, entry.label)
      |> maybe_append_field(:limit, entry.limit)

    block_entry("debug #{atom(entry.name)}", block, level)
  end

  defp entry_to_lines(%{type: :trace} = entry, _level) do
    opts = if entry.source, do: ["source: #{ref(entry.source)}"], else: []
    [line("trace(#{atom(entry.name)}#{opts_suffix(opts)})")]
  end

  defp entry_to_lines(%{type: :switch} = entry, level) do
    if Enum.any?(entry.matches, &Map.has_key?(&1, :flow)) or is_map(entry.default) do
      block =
        [line("on(#{ref(entry.on)})"), ""]
        |> Kernel.++(Enum.flat_map(entry.matches, &switch_match_lines(&1, level + 1)))
        |> maybe_append_switch_default(entry.default, level + 1)

      block_entry("switch #{atom(entry.name)}", block, level)
    else
      matches =
        entry.matches
        |> Enum.map(fn match ->
          "#{atom(match.name)}: {#{callable(match.predicate)}, #{atom(match.then)}}"
        end)
        |> Enum.join(", ")

      opts = [
        "on: #{ref(entry.on)}",
        "matches?: [#{matches}]",
        "default: #{value(entry.default)}",
        "return: #{value(entry.return?)}"
      ]

      [line("switch(#{atom(entry.name)}, #{Enum.join(opts, ", ")})")]
    end
  end

  defp entry_to_lines(entry, _level), do: [line("# unsupported entry #{inspect(entry.type)}")]

  defp switch_match_lines(match, level) do
    block =
      Enum.flat_map(match.flow, &entry_to_lines(&1, level + 1))
      |> maybe_append_return(match.return, level + 1)

    block_entry("matches? #{atom(match.name)}, #{callable(match.predicate)}", block, level) ++
      [""]
  end

  defp maybe_append_switch_default(lines, nil, _level), do: lines

  defp maybe_append_switch_default(lines, default, level) when is_map(default) do
    block =
      Enum.flat_map(default.flow, &entry_to_lines(&1, level + 1))
      |> maybe_append_return(default.return, level + 1)

    lines ++ block_entry("default", block, level)
  end

  defp maybe_append_switch_default(lines, _default, _level), do: lines

  defp block_entry(header, block, _level) do
    [line("#{header} do"), indent_lines(block, 1), line("end")]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
  end

  defp indent_lines(lines, level) when is_list(lines) do
    lines
    |> Enum.flat_map(fn
      "" -> [""]
      line -> [String.duplicate("  ", level) <> line]
    end)
  end

  defp line(value), do: value

  defp maybe_append_wait_for(lines, nil), do: lines

  defp maybe_append_wait_for(lines, dependency),
    do: lines ++ [line("wait_for(#{value(dependency)})")]

  defp maybe_append_source(lines, nil), do: lines
  defp maybe_append_source(lines, source), do: lines ++ [line("source(#{ref(source)})")]

  defp maybe_append_field(lines, _field, nil), do: lines
  defp maybe_append_field(lines, field, value), do: lines ++ [line("#{field}(#{value(value)})")]

  defp primitive_opts(entry, extra) do
    opts = []
    opts = if entry.after, do: opts ++ ["after: #{value(entry.after)}"], else: opts
    opts = opts ++ extra
    opts = if entry.inputs, do: opts ++ ["inputs: #{value(entry.inputs)}"], else: opts
    if entry.outputs, do: opts ++ ["outputs: #{value(entry.outputs)}"], else: opts
  end

  defp map_opt(%{map: nil}), do: []
  defp map_opt(%{map: map}), do: ["map: #{atom(map)}"]

  defp opts_suffix([]), do: ""
  defp opts_suffix(opts), do: ", " <> Enum.join(opts, ", ")

  defp mode_suffix(:value), do: ""
  defp mode_suffix(mode), do: ", mode: #{value(mode)}"

  defp ref({:input, name}), do: "input(#{atom(name)})"
  defp ref({:result, name}), do: "result(#{atom(name)})"
  defp ref({:result, name, path}), do: "result(#{atom(name)}, #{value(path)})"
  defp ref({:value, value}), do: "value(#{value(value)})"
  defp ref({:element, name}), do: "element(#{atom(name)})"
  defp ref(atom) when is_atom(atom), do: atom(atom)

  defp reference?({kind, _value}) when kind in [:input, :result, :value, :element], do: true
  defp reference?({:result, _name, _path}), do: true
  defp reference?(_value), do: false

  defp callable({module, function}), do: "{#{module(module)}, #{atom(function)}}"
  defp callable({:mfa, module, function}), do: "{:mfa, #{module(module)}, #{atom(function)}}"

  defp value(value), do: inspect(value, charlists: :as_lists)
  defp atom(nil), do: "nil"
  defp atom(value) when is_atom(value), do: inspect(value)
  defp module(value) when is_atom(value), do: inspect(value)

  defp script_error(meta, message) when is_list(meta) do
    location =
      case {Keyword.get(meta, :line), Keyword.get(meta, :column)} do
        {nil, _column} -> ""
        {line, nil} -> " at line #{line}"
        {line, column} -> " at line #{line}, column #{column}"
      end

    ArgumentError.exception("invalid flow script#{location}: #{message}")
  end

  defp script_error({form, meta, _args}, message) when is_atom(form) and is_list(meta),
    do: script_error(meta, message)

  defp script_error(_other, message),
    do: ArgumentError.exception("invalid flow script: #{message}")
end
