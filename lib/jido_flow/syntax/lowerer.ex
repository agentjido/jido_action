defmodule Jido.Flow.Syntax.Lowerer do
  @moduledoc """
  Lowers shared Flow syntax into canonical Flow artifacts.
  """

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Choice, Condition, Node, Ref, Syntax}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce, as: FlowReduce
  alias Jido.Flow.Syntax.{Expr, Operation}

  @type state :: %{
          nodes: [Node.t() | Choice.t() | FlowMap.t() | FlowReduce.t()],
          seen: MapSet.t(String.t()),
          bindings: %{optional(atom()) => String.t()},
          all_bindings: MapSet.t(atom()),
          all_nodes: MapSet.t(String.t()),
          branch: atom() | nil,
          return: term() | nil
        }

  @reserved_bindings MapSet.new([
                       :_,
                       :flow,
                       :step,
                       :return,
                       :input,
                       :context,
                       :value,
                       :result,
                       :select,
                       :map,
                       :reduce,
                       :item,
                       :item_index,
                       :item_id,
                       :accumulator,
                       :group,
                       :branch
                     ])

  @doc """
  Lowers a syntax artifact into `%Jido.Flow{}`.
  """
  @spec lower(Syntax.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def lower(%Syntax{} = syntax) do
    with {:ok, state} <- lower_operations(syntax.operations),
         {:ok, return_ref} <- require_return(state.return) do
      Flow.new(
        name: syntax.name,
        description: syntax.description,
        schema: syntax.schema,
        output_schema: syntax.output_schema,
        nodes: Enum.reverse(state.nodes),
        return: return_ref,
        provenance: syntax.provenance
      )
    end
  end

  defp lower_operations(operations) when not is_list(operations) do
    {:error,
     Error.validation_error("flow syntax operations must be a list", %{operations: operations})}
  end

  defp lower_operations(operations) do
    operations = normalize_derived_node_names(operations)

    with :ok <- validate_source_namespace(operations) do
      initial_state = %{
        nodes: [],
        seen: MapSet.new(),
        bindings: %{},
        all_bindings: operations |> binding_aliases() |> MapSet.new(),
        all_nodes: operations |> node_names() |> MapSet.new(),
        branch: nil,
        return: nil
      }

      Enum.reduce_while(operations, {:ok, initial_state}, fn operation, {:ok, state} ->
        case lower_operation(operation, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp lower_operation(%Operation{kind: :step, attrs: attrs, provenance: provenance}, state) do
    step_name = attrs |> Map.get(:name) |> normalize_step_name()
    binding = Map.get(attrs, :binding)
    input_expr = Map.get(attrs, :input, %{})
    after_targets = Map.get(attrs, :after, [])

    with :ok <- validate_no_self_reference(input_expr, binding, step_name),
         {:ok, explicit_deps} <- resolve_after_targets(after_targets, state, step_name, binding),
         {:ok, input} <- resolve_expr(input_expr, state, step_name),
         {:ok, provenance} <- normalize_step_provenance(provenance, step_name),
         {:ok, node} <-
           Node.new(
             name: step_name,
             action: Map.get(attrs, :action),
             input: input,
             deps: explicit_deps,
             provenance:
               provenance
               |> maybe_put_binding(binding)
               |> maybe_put_branch(state.branch)
           ) do
      {:ok, put_node(state, node, binding)}
    end
  end

  defp lower_operation(%Operation{kind: :map, attrs: attrs, provenance: provenance}, state) do
    map_name = attrs |> Map.get(:name) |> normalize_step_name()
    binding = Map.get(attrs, :binding)
    collection_expr = Map.get(attrs, :collection)
    input_expr = Map.get(attrs, :input)
    after_targets = Map.get(attrs, :after, [])

    with :ok <- validate_operation_options(:map, attrs),
         :ok <- validate_no_self_reference([collection_expr, input_expr], binding, map_name),
         :ok <- validate_no_self_result([collection_expr, input_expr], map_name),
         {:ok, explicit_deps} <- resolve_after_targets(after_targets, state, map_name, binding),
         {:ok, collection} <- resolve_expr(collection_expr, state, map_name),
         {:ok, input} <- resolve_expr(input_expr, state, map_name),
         {:ok, provenance} <- normalize_step_provenance(provenance, map_name),
         {:ok, map} <-
           FlowMap.new(
             name: map_name,
             collection: collection,
             action: Map.get(attrs, :action),
             input: input,
             on_error: Map.get(attrs, :on_error, :fail_fast),
             deps: explicit_deps,
             provenance: maybe_put_binding(provenance, binding)
           ) do
      {:ok, put_node(state, map, binding)}
    end
  end

  defp lower_operation(%Operation{kind: :reduce, attrs: attrs, provenance: provenance}, state) do
    reduce_name = attrs |> Map.get(:name) |> normalize_step_name()
    binding = Map.get(attrs, :binding)
    collection_expr = Map.get(attrs, :collection)
    initial_expr = Map.get(attrs, :initial)
    input_expr = Map.get(attrs, :input)
    after_targets = Map.get(attrs, :after, [])

    with :ok <- validate_operation_options(:reduce, attrs),
         :ok <-
           validate_no_self_reference(
             [collection_expr, initial_expr, input_expr],
             binding,
             reduce_name
           ),
         :ok <- validate_no_self_result([collection_expr, initial_expr, input_expr], reduce_name),
         {:ok, explicit_deps} <-
           resolve_after_targets(after_targets, state, reduce_name, binding),
         {:ok, collection} <- resolve_expr(collection_expr, state, reduce_name),
         {:ok, initial} <- resolve_expr(initial_expr, state, reduce_name),
         {:ok, input} <- resolve_expr(input_expr, state, reduce_name),
         {:ok, provenance} <- normalize_step_provenance(provenance, reduce_name),
         {:ok, reduce} <-
           FlowReduce.new(
             name: reduce_name,
             collection: collection,
             initial: initial,
             action: Map.get(attrs, :action),
             input: input,
             deps: explicit_deps,
             provenance: maybe_put_binding(provenance, binding)
           ) do
      {:ok, put_node(state, reduce, binding)}
    end
  end

  defp lower_operation(%Operation{kind: :choice, attrs: attrs, provenance: provenance}, state) do
    choice_name = attrs |> Map.get(:name) |> normalize_step_name()
    binding = Map.get(attrs, :binding)
    options = Map.get(attrs, :options)
    fallback = Map.get(attrs, :fallback)
    after_targets = Map.get(attrs, :after, [])

    with :ok <- validate_no_self_reference([options, fallback], binding, choice_name),
         {:ok, explicit_deps} <- resolve_after_targets(after_targets, state, choice_name, binding),
         {:ok, options} <- resolve_choice_options(options, state, choice_name),
         {:ok, fallback} <- resolve_choice_fallback(fallback, state, choice_name),
         {:ok, provenance} <- normalize_step_provenance(provenance, choice_name),
         {:ok, choice} <-
           Choice.new(
             name: choice_name,
             options: options,
             fallback: fallback,
             deps: explicit_deps,
             provenance: provenance |> maybe_put_binding(binding)
           ) do
      {:ok, put_node(state, choice, binding)}
    end
    |> add_choice_context(choice_name)
  end

  defp lower_operation(%Operation{kind: :group, attrs: attrs}, state) do
    with {:ok, branches} <- validate_group_branches(Map.get(attrs, :branches, [])),
         {:ok, branch_states} <- lower_group_branches(branches, state) do
      new_nodes =
        branch_states
        |> Enum.flat_map(fn branch_state -> Enum.reverse(branch_state.nodes) end)

      seen =
        Enum.reduce(branch_states, state.seen, fn branch_state, acc ->
          MapSet.union(acc, branch_state.seen)
        end)

      bindings =
        Enum.reduce(branch_states, state.bindings, fn branch_state, acc ->
          Map.merge(acc, branch_state.bindings)
        end)

      {:ok,
       %{
         state
         | nodes: Enum.reverse(new_nodes) ++ state.nodes,
           seen: seen,
           bindings: bindings
       }}
    end
  end

  defp lower_operation(%Operation{kind: :return}, %{return: return}) when not is_nil(return) do
    {:error, Error.validation_error("duplicate return declaration", %{operation: :return})}
  end

  defp lower_operation(%Operation{kind: :return, attrs: attrs}, state) do
    with {:ok, expr} <- resolve_expr(Map.get(attrs, :expr), state, nil),
         {:ok, expr} <- validate_return_expr(expr) do
      {:ok, %{state | return: expr}}
    end
  end

  defp lower_operation(%Operation{kind: kind}, _state) do
    {:error,
     Error.validation_error("unsupported flow syntax operation: #{inspect(kind)}", %{kind: kind})}
  end

  defp lower_operation(operation, _state) do
    {:error,
     Error.validation_error("unsupported flow syntax operation: #{inspect(operation)}", %{
       operation: operation
     })}
  end

  defp normalize_derived_node_names(operations) when is_list(operations) do
    Enum.map(operations, &normalize_derived_node_name/1)
  end

  defp normalize_derived_node_names(operations), do: operations

  defp normalize_derived_node_name(%Operation{kind: kind, attrs: attrs} = operation)
       when kind in [:step, :choice, :map, :reduce] do
    case {Map.get(attrs, :name), Map.get(attrs, :binding)} do
      {nil, binding} when is_atom(binding) and not is_nil(binding) ->
        %{
          operation
          | attrs:
              attrs
              |> Map.put(:name, Atom.to_string(binding))
              |> Map.put(:derived_name?, true)
        }

      _other ->
        operation
    end
  end

  defp normalize_derived_node_name(%Operation{kind: :group, attrs: attrs} = operation) do
    case Map.get(attrs, :branches) do
      branches when is_list(branches) ->
        %{
          operation
          | attrs: Map.put(attrs, :branches, normalize_derived_branch_step_names(branches))
        }

      _branches ->
        operation
    end
  end

  defp normalize_derived_node_name(operation), do: operation

  defp normalize_derived_branch_step_names(branches) when is_list(branches) do
    Enum.map(branches, fn
      %Operation{kind: :branch, attrs: attrs} = branch ->
        operations =
          attrs
          |> Map.get(:operations)
          |> normalize_derived_node_names()

        %{branch | attrs: Map.put(attrs, :operations, operations)}

      branch ->
        branch
    end)
  end

  defp resolve_expr(%Expr{type: :input, path: path}, _state, _step), do: {:ok, Ref.input(path)}

  defp resolve_expr(%Expr{type: :context, path: path}, _state, _step),
    do: {:ok, Ref.context(path)}

  defp resolve_expr(%Expr{type: :value, value: value}, _state, _step), do: {:ok, Ref.value(value)}

  defp resolve_expr(%Expr{type: :result, node: node, path: path}, state, step) do
    node = normalize_step_name(node)

    if MapSet.member?(state.seen, node) do
      {:ok, Ref.result(node, path)}
    else
      result_before_bound_error(step, node)
    end
  end

  defp resolve_expr(%Expr{type: :binding, binding: binding}, state, step) do
    cond do
      Map.has_key?(state.bindings, binding) ->
        {:ok, Ref.result(Map.fetch!(state.bindings, binding))}

      MapSet.member?(state.all_bindings, binding) ->
        binding_before_bound_error(step, binding)

      true ->
        unknown_binding_error(step, binding)
    end
  end

  defp resolve_expr(%Expr{type: :select, source: source, path: path}, state, step) do
    with {:ok, source_ref} <- resolve_expr(source, state, step),
         {:ok, source_ref} <- validate_select_source(source_ref, step) do
      path = source_ref.path ++ path

      with :ok <- validate_select_path(path, step) do
        {:ok, %{source_ref | path: path}}
      end
    end
  end

  defp resolve_expr(%Expr{type: :item, path: path}, _state, _step),
    do: {:ok, Ref.item(path)}

  defp resolve_expr(%Expr{type: :item_index}, _state, _step), do: {:ok, Ref.item_index()}
  defp resolve_expr(%Expr{type: :item_id}, _state, _step), do: {:ok, Ref.item_id()}

  defp resolve_expr(%Expr{type: :accumulator, path: path}, _state, _step),
    do: {:ok, Ref.accumulator(path)}

  defp resolve_expr(%Expr{type: type}, _state, step) do
    {:error,
     Error.validation_error("unsupported flow syntax expression: #{inspect(type)}", %{
       step: step,
       type: type
     })}
  end

  defp resolve_expr(%Ref{type: :result, node: node, path: path}, state, step) do
    resolve_expr(%Expr{type: :result, node: node, path: path}, state, step)
  end

  defp resolve_expr(%Ref{} = ref, _state, _step), do: {:ok, ref}

  defp resolve_expr(%{} = map, state, step) when not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_expr(value, state, step) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_expr(list, state, step) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_expr(value, state, step) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_expr(value, _state, _step), do: {:ok, Ref.value(value)}

  defp resolve_choice_options(options, _state, choice) when not is_list(options) do
    {:error,
     Error.validation_error("choice options must be a list", %{choice: choice, field: :options})}
  end

  defp resolve_choice_options(options, state, choice) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, acc} ->
      case resolve_choice_option(option, state, choice, index) do
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, options} -> {:ok, Enum.reverse(options)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_choice_option(%Syntax.Option{} = option, state, choice, index) do
    with {:ok, condition} <- resolve_choice_condition(option.condition, state, choice, index),
         {:ok, input} <- resolve_expr(option.input, state, choice) do
      {:ok,
       %{
         name: option.name,
         condition: condition,
         action: option.action,
         input: input
       }}
    end
  end

  defp resolve_choice_option(_option, _state, choice, index) do
    {:error,
     Error.validation_error("choice option must be a Jido.Flow.Syntax.Option", %{
       choice: choice,
       option: index,
       field: :options
     })}
  end

  defp resolve_choice_fallback(%Syntax.Fallback{} = fallback, state, choice) do
    with {:ok, input} <- resolve_expr(fallback.input, state, choice) do
      {:ok, %{action: fallback.action, input: input}}
    end
  end

  defp resolve_choice_fallback(nil, _state, choice) do
    {:error,
     Error.validation_error("choice fallback is required", %{choice: choice, field: :fallback})}
  end

  defp resolve_choice_fallback(_fallback, _state, choice) do
    {:error,
     Error.validation_error("choice fallback must be a Jido.Flow.Syntax.Fallback", %{
       choice: choice,
       field: :fallback
     })}
  end

  defp resolve_choice_condition(
         %Syntax.Condition{operator: operator, operands: operands},
         state,
         choice,
         option
       )
       when operator in [:eq, :neq, :lt, :lte, :gt, :gte, :in] do
    with {:ok, operands} <- resolve_choice_operands(operands, state, choice),
         {:ok, condition} <- Condition.new(operator, operands) do
      {:ok, condition}
    else
      {:error, error} -> {:error, add_choice_error_context(error, choice, option)}
    end
  end

  defp resolve_choice_condition(
         %Syntax.Condition{operator: operator, operands: operands},
         state,
         choice,
         option
       )
       when operator in [:all, :any, :not] do
    with {:ok, operands} <- resolve_choice_conditions(operands, state, choice, option),
         {:ok, condition} <- Condition.new(operator, operands) do
      {:ok, condition}
    else
      {:error, error} -> {:error, add_choice_error_context(error, choice, option)}
    end
  end

  defp resolve_choice_condition(%Syntax.Condition{} = condition, _state, choice, option) do
    case Condition.new(condition.operator, condition.operands) do
      {:ok, _condition} ->
        {:error,
         Error.validation_error("unsupported choice condition source", %{
           choice: choice,
           option: option,
           operator: condition.operator
         })}

      {:error, error} ->
        {:error, add_choice_error_context(error, choice, option)}
    end
  end

  defp resolve_choice_condition(_condition, _state, choice, option) do
    {:error,
     Error.validation_error("choice option condition must be a Jido.Flow.Syntax.Condition", %{
       choice: choice,
       option: option,
       field: :condition
     })}
  end

  defp resolve_choice_operands(operands, _state, _choice) when not is_list(operands) do
    {:error, Error.validation_error("choice condition operands must be a list")}
  end

  defp resolve_choice_operands(operands, state, choice) do
    resolve_expr(operands, state, choice)
  end

  defp resolve_choice_conditions(conditions, _state, _choice, _option)
       when not is_list(conditions) do
    {:error, Error.validation_error("choice condition operands must be a list")}
  end

  defp resolve_choice_conditions(conditions, state, choice, option) do
    conditions
    |> Enum.reduce_while({:ok, []}, fn condition, {:ok, acc} ->
      case resolve_choice_condition(condition, state, choice, option) do
        {:ok, condition} -> {:cont, {:ok, [condition | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, conditions} -> {:ok, Enum.reverse(conditions)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_after_targets(nil, _state, _step, _binding), do: {:ok, []}

  defp resolve_after_targets(targets, state, step, binding) do
    targets = if is_list(targets), do: targets, else: [targets]

    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case resolve_after_target(target, state, step, binding) do
        {:ok, dependency} -> {:cont, {:ok, [dependency | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, dependencies} -> {:ok, dependencies |> Enum.reverse() |> Enum.uniq()}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_after_target(target, state, step, _binding)
       when (is_atom(target) and not is_nil(target)) or is_binary(target) do
    target_name = normalize_step_name(target)

    cond do
      target_name == step ->
        self_dependency_error(step, target_name)

      MapSet.member?(state.seen, target_name) ->
        {:ok, target_name}

      MapSet.member?(state.all_nodes, target_name) ->
        explicit_dependency_before_bound_error(step, target_name)

      true ->
        unknown_explicit_dependency_error(step, target_name)
    end
  end

  defp resolve_after_target(%Expr{type: :binding, binding: target_binding}, state, step, binding) do
    cond do
      target_binding == binding ->
        self_binding_dependency_error(step, target_binding)

      Map.has_key?(state.bindings, target_binding) ->
        {:ok, Map.fetch!(state.bindings, target_binding)}

      MapSet.member?(state.all_bindings, target_binding) ->
        binding_before_bound_error(step, target_binding)

      true ->
        unknown_binding_error(step, target_binding)
    end
  end

  defp resolve_after_target(%Expr{type: type}, _state, step, _binding) do
    unsupported_after_target_error(step, type)
  end

  defp resolve_after_target(%Ref{type: type}, _state, step, _binding) do
    unsupported_after_target_error(step, type)
  end

  defp resolve_after_target(target, _state, step, _binding) do
    unsupported_after_target_error(step, target)
  end

  defp validate_return_expr(expr) do
    case Node.collect_result_refs(expr) do
      [] -> {:error, Error.validation_error("return must reference at least one step result")}
      _refs -> {:ok, expr}
    end
  end

  defp validate_group_branches(branches) when is_list(branches) do
    with :ok <- validate_branch_shapes(branches),
         :ok <- validate_duplicate_branch_names(branches) do
      {:ok, branches}
    end
  end

  defp validate_group_branches(branches) do
    {:error, Error.validation_error("group branches must be a list", %{branches: branches})}
  end

  defp validate_branch_shapes(branches) do
    Enum.reduce_while(branches, :ok, fn
      %Operation{kind: :branch, attrs: attrs}, :ok ->
        name = Map.get(attrs, :name)
        operations = Map.get(attrs, :operations)

        cond do
          not valid_branch_name?(name) ->
            {:halt, branch_name_error(name)}

          not is_list(operations) ->
            {:halt, branch_operations_error(name, operations)}

          true ->
            {:cont, :ok}
        end

      %Operation{kind: kind}, :ok ->
        {:halt, group_branch_operation_error(kind)}

      branch, :ok ->
        {:halt, group_branch_value_error(branch)}
    end)
  end

  defp validate_duplicate_branch_names(branches) do
    branch_names = Enum.map(branches, fn %Operation{attrs: attrs} -> Map.fetch!(attrs, :name) end)

    case Enum.find(branch_names, fn name -> Enum.count(branch_names, &(&1 == name)) > 1 end) do
      nil ->
        :ok

      branch ->
        {:error,
         Error.validation_error("duplicate branch name: #{inspect(branch)}", %{branch: branch})}
    end
  end

  defp valid_branch_name?(name), do: is_atom(name) and not is_nil(name)

  defp lower_group_branches(branches, state) do
    Enum.reduce_while(branches, {:ok, []}, fn branch, {:ok, acc} ->
      %Operation{attrs: %{name: branch_name, operations: operations}} = branch

      branch_state = %{
        state
        | nodes: [],
          branch: branch_name
      }

      case lower_branch_operations(operations, branch_state) do
        {:ok, branch_state} -> {:cont, {:ok, acc ++ [branch_state]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lower_branch_operations(operations, state) do
    Enum.reduce_while(operations, {:ok, state}, fn
      %Operation{kind: :step} = operation, {:ok, state} ->
        case lower_operation(operation, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, error} -> {:halt, {:error, error}}
        end

      %Operation{kind: kind}, {:ok, state} ->
        {:halt, branch_step_operation_error(state.branch, kind)}

      operation, {:ok, state} ->
        {:halt, branch_step_value_error(state.branch, operation)}
    end)
  end

  defp validate_select_source(%Ref{type: type} = ref, _step)
       when type in [:input, :context, :result, :item, :accumulator] do
    {:ok, ref}
  end

  defp validate_select_source(source, step) do
    {:error,
     Error.validation_error("select source must resolve to an input, context, or result ref", %{
       step: step,
       type: select_source_type(source)
     })}
  end

  defp select_source_type(%Ref{type: type}), do: type
  defp select_source_type(%{}), do: :map
  defp select_source_type(list) when is_list(list), do: :list

  defp validate_select_path(path, step) do
    case Enum.find_index(path, &(not valid_select_path_segment?(&1))) do
      nil ->
        :ok

      index ->
        segment = Enum.at(path, index)

        {:error,
         Error.validation_error("select path segments must be atoms, strings, or integers", %{
           step: step,
           path: path,
           segment: segment
         })}
    end
  end

  defp valid_select_path_segment?(segment) do
    (is_atom(segment) and not is_nil(segment)) or is_binary(segment) or is_integer(segment)
  end

  defp require_return(nil) do
    {:error, Error.validation_error("return ref is required", %{operation: :return})}
  end

  defp require_return(return), do: {:ok, return}

  defp validate_source_namespace(operations) do
    aliases = binding_aliases(operations)

    with :ok <- validate_step_name_presence(operations),
         :ok <- validate_binding_alias_shapes(aliases),
         :ok <- validate_duplicate_bindings(aliases),
         :ok <- validate_reserved_bindings(aliases),
         :ok <- validate_binding_step_collisions(operations) do
      :ok
    end
  end

  defp validate_step_name_presence(operations) do
    case Enum.find(node_operations(operations), &is_nil(Map.get(&1.attrs, :name))) do
      nil ->
        :ok

      %Operation{kind: kind, attrs: attrs} ->
        {:error,
         Error.validation_error("#{kind} requires a name or a binding", %{
           binding: Map.get(attrs, :binding)
         })}
    end
  end

  defp binding_aliases(operations) do
    operations
    |> node_operations()
    |> Enum.flat_map(fn %Operation{attrs: attrs} ->
      case Map.get(attrs, :binding) do
        nil -> []
        binding -> [binding]
      end
    end)
  end

  defp node_names(operations) do
    operations
    |> node_operations()
    |> Enum.flat_map(fn %Operation{attrs: attrs} ->
      case Map.get(attrs, :name) do
        name when (is_atom(name) and not is_nil(name)) or is_binary(name) ->
          [normalize_step_name(name)]

        _name ->
          []
      end
    end)
  end

  defp node_operations(operations) when is_list(operations) do
    Enum.flat_map(operations, fn
      %Operation{kind: kind} = operation when kind in [:step, :choice, :map, :reduce] ->
        [operation]

      %Operation{kind: :group, attrs: attrs} ->
        attrs
        |> Map.get(:branches, [])
        |> branch_step_operations()

      _operation ->
        []
    end)
  end

  defp node_operations(_operations), do: []

  defp branch_step_operations(branches) when is_list(branches) do
    Enum.flat_map(branches, fn
      %Operation{kind: :branch, attrs: attrs} ->
        attrs
        |> Map.get(:operations, [])
        |> direct_step_operations()

      _branch ->
        []
    end)
  end

  defp branch_step_operations(_branches), do: []

  defp direct_step_operations(operations) when is_list(operations) do
    Enum.filter(operations, &match?(%Operation{kind: :step}, &1))
  end

  defp direct_step_operations(_operations), do: []

  defp validate_binding_alias_shapes(aliases) do
    case Enum.find(aliases, &(not is_atom(&1) or is_nil(&1))) do
      nil ->
        :ok

      binding ->
        {:error,
         Error.validation_error("binding alias must be a non-nil atom", %{binding: binding})}
    end
  end

  defp validate_duplicate_bindings(aliases) do
    frequencies = Enum.frequencies(aliases)

    case Enum.find(aliases, &(Map.fetch!(frequencies, &1) > 1)) do
      nil ->
        :ok

      binding ->
        {:error,
         Error.validation_error("duplicate binding alias: #{inspect(binding)}", %{
           binding: binding
         })}
    end
  end

  defp validate_reserved_bindings(aliases) do
    case Enum.find(aliases, &MapSet.member?(@reserved_bindings, &1)) do
      nil ->
        :ok

      binding ->
        {:error,
         Error.validation_error("reserved binding alias: #{inspect(binding)}", %{
           binding: binding
         })}
    end
  end

  defp validate_binding_step_collisions(operations) do
    step_name_set = operations |> node_names() |> MapSet.new()

    case Enum.find(node_operations(operations), fn %Operation{attrs: attrs} ->
           binding = Map.get(attrs, :binding)
           name = attrs |> Map.get(:name) |> normalize_step_name()
           derived_name? = Map.get(attrs, :derived_name?, false)
           binding_name = normalize_step_name(binding)

           is_atom(binding) and not is_nil(binding) and
             MapSet.member?(step_name_set, binding_name) and
             not (derived_name? and binding_name == name)
         end) do
      nil ->
        :ok

      %Operation{attrs: attrs} ->
        binding = Map.fetch!(attrs, :binding)

        {:error,
         Error.validation_error("binding alias conflicts with step name: #{inspect(binding)}", %{
           binding: binding
         })}
    end
  end

  defp validate_no_self_reference(_expr, nil, _step), do: :ok

  defp validate_no_self_reference(expr, binding, step) do
    if binding_referenced?(expr, binding) do
      {:error,
       Error.validation_error("binding cannot reference itself: #{inspect(binding)}", %{
         step: step,
         binding: binding
       })}
    else
      :ok
    end
  end

  defp validate_no_self_result(_expr, nil), do: :ok

  defp validate_no_self_result(expr, step) do
    if result_referenced?(expr, step) do
      {:error,
       Error.validation_error("result cannot reference current step: #{inspect(step)}", %{
         step: step,
         dependency: step
       })}
    else
      :ok
    end
  end

  defp result_referenced?(%Expr{type: :result, node: node}, step),
    do: normalize_step_name(node) == step

  defp result_referenced?(%Expr{type: :select, source: source}, step),
    do: result_referenced?(source, step)

  defp result_referenced?(%Expr{}, _step), do: false

  defp result_referenced?(%Ref{type: :result, node: node}, step), do: node == step
  defp result_referenced?(%Ref{}, _step), do: false

  defp result_referenced?(%{} = map, step) do
    map
    |> Map.values()
    |> Enum.any?(&result_referenced?(&1, step))
  end

  defp result_referenced?(list, step) when is_list(list) do
    Enum.any?(list, &result_referenced?(&1, step))
  end

  defp result_referenced?(_value, _step), do: false

  defp binding_referenced?(%Expr{type: :binding, binding: binding}, binding), do: true

  defp binding_referenced?(%Expr{type: :select, source: source}, binding),
    do: binding_referenced?(source, binding)

  defp binding_referenced?(%Expr{}, _binding), do: false
  defp binding_referenced?(%Ref{}, _binding), do: false

  defp binding_referenced?(%{} = map, binding) do
    map
    |> Map.values()
    |> Enum.any?(&binding_referenced?(&1, binding))
  end

  defp binding_referenced?(list, binding) when is_list(list) do
    Enum.any?(list, &binding_referenced?(&1, binding))
  end

  defp binding_referenced?(_value, _binding), do: false

  defp maybe_put_binding(provenance, nil), do: provenance
  defp maybe_put_binding(provenance, binding), do: Map.put(provenance, :binding, binding)

  defp maybe_put_branch(provenance, nil), do: provenance
  defp maybe_put_branch(provenance, branch), do: Map.put(provenance, :branch, branch)

  defp maybe_bind(bindings, nil, _node), do: bindings
  defp maybe_bind(bindings, binding, node), do: Map.put(bindings, binding, node)

  defp put_node(state, node, binding) do
    %{
      state
      | nodes: [node | state.nodes],
        seen: MapSet.put(state.seen, node.name),
        bindings: maybe_bind(state.bindings, binding, node.name)
    }
  end

  defp validate_operation_options(kind, attrs) do
    allowed =
      case kind do
        :map ->
          [:name, :collection, :action, :input, :on_error, :binding, :after, :derived_name?]

        :reduce ->
          [:name, :collection, :initial, :action, :input, :binding, :after, :derived_name?]
      end

    case Map.get(attrs, :option_errors, []) do
      [{:unsupported, option} | _rest] ->
        operation_option_error(kind, :unsupported, option)

      [{:duplicate, option} | _rest] ->
        operation_option_error(kind, :duplicate, option)

      [{:invalid, options} | _rest] ->
        {:error,
         Error.validation_error("#{kind} options must be a keyword list", %{
           path: [:options],
           options: options
         })}

      [] ->
        case attrs
             |> Map.keys()
             |> Enum.reject(&(&1 == :option_errors or &1 in allowed))
             |> Enum.sort()
             |> List.first() do
          nil -> :ok
          option -> operation_option_error(kind, :unsupported, option)
        end
    end
  end

  defp operation_option_error(kind, reason, option) do
    {:error,
     Error.validation_error("#{reason} #{kind} option: #{inspect(option)}", %{
       path: [:options, option],
       option: option
     })}
  end

  defp add_choice_context({:ok, _choice} = result, _choice_name), do: result

  defp add_choice_context({:error, error}, choice_name) do
    {:error, add_choice_error_context(error, choice_name)}
  end

  defp add_choice_error_context(error, choice_name, option \\ nil) do
    details = Map.get(error, :details, %{}) |> Map.put_new(:choice, choice_name)
    details = if is_nil(option), do: details, else: Map.put_new(details, :option, option)
    Error.validation_error(error.message, details)
  end

  defp normalize_step_name(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp normalize_step_name(name) when is_binary(name), do: name
  defp normalize_step_name(_name), do: nil

  defp normalize_step_provenance(provenance, step) when is_map(provenance) do
    with {:ok, provenance} <- normalize_annotation_string(provenance, :label, step),
         {:ok, provenance} <- normalize_annotation_string(provenance, :note, step),
         {:ok, provenance} <- normalize_annotation_tags(provenance, step) do
      {:ok, provenance}
    end
  end

  defp normalize_step_provenance(provenance, _step), do: {:ok, provenance}

  defp normalize_annotation_string(provenance, field, step) do
    case Map.fetch(provenance, field) do
      :error ->
        {:ok, provenance}

      {:ok, value} when is_binary(value) ->
        {:ok, provenance}

      {:ok, value} ->
        {:error,
         Error.validation_error("step annotation #{field} must be a string", %{
           step: step,
           field: field,
           value: value
         })}
    end
  end

  defp normalize_annotation_tags(provenance, step) do
    case Map.fetch(provenance, :tags) do
      :error ->
        {:ok, provenance}

      {:ok, tags} when is_list(tags) ->
        normalize_tags(tags, step)
        |> case do
          {:ok, tags} -> {:ok, Map.put(provenance, :tags, tags)}
          {:error, error} -> {:error, error}
        end

      {:ok, value} ->
        {:error,
         Error.validation_error("step annotation tags must be a list", %{
           step: step,
           field: :tags,
           value: value
         })}
    end
  end

  defp normalize_tags(tags, step) do
    Enum.reduce_while(tags, {:ok, []}, fn
      tag, {:ok, acc} when is_binary(tag) ->
        {:cont, {:ok, [tag | acc]}}

      tag, {:ok, acc} when is_atom(tag) and not is_nil(tag) ->
        {:cont, {:ok, [Atom.to_string(tag) | acc]}}

      tag, {:ok, _acc} ->
        {:halt,
         {:error,
          Error.validation_error("step annotation tags must be strings or atoms", %{
            step: step,
            field: :tags,
            value: tag
          })}}
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.reverse(tags)}
      {:error, error} -> {:error, error}
    end
  end

  defp result_before_bound_error(step, dependency) do
    {:error,
     Error.validation_error("result reference before it is bound: #{inspect(dependency)}", %{
       step: step,
       dependency: dependency
     })}
  end

  defp binding_before_bound_error(step, binding) do
    {:error,
     Error.validation_error("binding reference before it is bound: #{inspect(binding)}", %{
       step: step,
       binding: binding
     })}
  end

  defp unknown_binding_error(step, binding) do
    {:error,
     Error.validation_error("unknown binding handle: #{inspect(binding)}", %{
       step: step,
       binding: binding
     })}
  end

  defp explicit_dependency_before_bound_error(step, dependency) do
    {:error,
     Error.validation_error("explicit dependency before it is bound: #{inspect(dependency)}", %{
       step: step,
       dependency: dependency
     })}
  end

  defp unknown_explicit_dependency_error(step, dependency) do
    {:error,
     Error.validation_error("unknown explicit dependency: #{inspect(dependency)}", %{
       step: step,
       dependency: dependency
     })}
  end

  defp self_dependency_error(step, dependency) do
    {:error,
     Error.validation_error(
       "explicit dependency cannot reference current step: #{inspect(dependency)}",
       %{
         step: step,
         dependency: dependency
       }
     )}
  end

  defp self_binding_dependency_error(step, binding) do
    {:error,
     Error.validation_error(
       "explicit dependency cannot reference current binding: #{inspect(binding)}",
       %{
         step: step,
         binding: binding
       }
     )}
  end

  defp unsupported_after_target_error(step, type) when is_atom(type) do
    {:error,
     Error.validation_error("after targets must be step names or binding handles", %{
       step: step,
       type: type
     })}
  end

  defp unsupported_after_target_error(step, target) do
    {:error,
     Error.validation_error("after targets must be step names or binding handles", %{
       step: step,
       target: target
     })}
  end

  defp branch_name_error(branch) do
    {:error, Error.validation_error("branch name must be a non-nil atom", %{branch: branch})}
  end

  defp branch_operations_error(branch, operations) do
    {:error,
     Error.validation_error("branch operations must be a list", %{
       branch: branch,
       operations: operations
     })}
  end

  defp group_branch_operation_error(kind) do
    {:error,
     Error.validation_error("group operations may contain only branch operations", %{kind: kind})}
  end

  defp group_branch_value_error(branch) do
    {:error,
     Error.validation_error("group operations may contain only branch operations", %{
       branch: branch
     })}
  end

  defp branch_step_operation_error(branch, kind) do
    {:error,
     Error.validation_error("group branches may contain only step operations", %{
       branch: branch,
       kind: kind
     })}
  end

  defp branch_step_value_error(branch, operation) do
    {:error,
     Error.validation_error("group branches may contain only step operations", %{
       branch: branch,
       operation: operation
     })}
  end
end
