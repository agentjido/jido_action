defmodule Jido.Flow.Syntax.Lowerer do
  @moduledoc """
  Lowers shared Flow syntax into canonical Flow artifacts.
  """

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref, Syntax}
  alias Jido.Flow.Syntax.{Expr, Operation}

  @type state :: %{
          nodes: [Node.t()],
          seen: MapSet.t(atom()),
          bindings: %{optional(atom()) => atom()},
          all_bindings: MapSet.t(atom()),
          return: Ref.t() | nil
        }

  @reserved_bindings MapSet.new([
                       :_,
                       :flow,
                       :step,
                       :return,
                       :input,
                       :value,
                       :result,
                       :select,
                       :shape
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

  defp lower_operations(operations) do
    with :ok <- validate_source_namespace(operations) do
      initial_state = %{
        nodes: [],
        seen: MapSet.new(),
        bindings: %{},
        all_bindings: operations |> binding_aliases() |> MapSet.new(),
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
    step_name = Map.get(attrs, :name)
    binding = Map.get(attrs, :binding)
    input_expr = Map.get(attrs, :input, %{})

    with :ok <- validate_no_self_reference(input_expr, binding, step_name),
         {:ok, input} <- resolve_expr(input_expr, state, step_name),
         {:ok, node} <-
           Node.new(
             name: step_name,
             action: Map.get(attrs, :action),
             input: input,
             provenance: maybe_put_binding(provenance, binding)
           ) do
      {:ok,
       %{
         state
         | nodes: [node | state.nodes],
           seen: MapSet.put(state.seen, node.name),
           bindings: maybe_bind(state.bindings, binding, node.name)
       }}
    end
  end

  defp lower_operation(%Operation{kind: :return, attrs: attrs}, state) do
    with {:ok, ref} <- resolve_expr(Map.get(attrs, :expr), state, nil),
         {:ok, ref} <- validate_return_ref(ref) do
      {:ok, %{state | return: ref}}
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

  defp resolve_expr(%Expr{type: :input, path: path}, _state, _step), do: {:ok, Ref.input(path)}
  defp resolve_expr(%Expr{type: :value, value: value}, _state, _step), do: {:ok, Ref.value(value)}

  defp resolve_expr(%Expr{type: :result, node: node, path: path}, state, step) do
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

  defp resolve_expr(%Expr{type: :shape, data: data}, state, step) do
    resolve_expr(data, state, step)
  end

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

  defp resolve_expr(%{} = map, state, step) do
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

  defp validate_return_ref(%Ref{type: :result} = ref), do: {:ok, ref}

  defp validate_return_ref(_ref) do
    {:error, Error.validation_error("return must resolve to a result ref")}
  end

  defp validate_select_source(%Ref{type: type} = ref, _step) when type in [:input, :result] do
    {:ok, ref}
  end

  defp validate_select_source(source, step) do
    {:error,
     Error.validation_error("select source must resolve to an input or result ref", %{
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

  defp require_return(%Ref{} = ref), do: {:ok, ref}

  defp validate_source_namespace(operations) do
    aliases = binding_aliases(operations)
    step_names = step_names(operations)

    with :ok <- validate_binding_alias_shapes(aliases),
         :ok <- validate_duplicate_bindings(aliases),
         :ok <- validate_reserved_bindings(aliases),
         :ok <- validate_binding_step_collisions(aliases, step_names) do
      :ok
    end
  end

  defp binding_aliases(operations) do
    operations
    |> Enum.flat_map(fn
      %Operation{kind: :step, attrs: attrs} ->
        case Map.get(attrs, :binding) do
          nil -> []
          binding -> [binding]
        end

      _operation ->
        []
    end)
  end

  defp step_names(operations) do
    operations
    |> Enum.flat_map(fn
      %Operation{kind: :step, attrs: attrs} ->
        case Map.get(attrs, :name) do
          name when is_atom(name) and not is_nil(name) -> [name]
          _name -> []
        end

      _operation ->
        []
    end)
  end

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
    case Enum.find(aliases, fn binding -> Enum.count(aliases, &(&1 == binding)) > 1 end) do
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

  defp validate_binding_step_collisions(aliases, step_names) do
    step_name_set = MapSet.new(step_names)

    case Enum.find(aliases, &MapSet.member?(step_name_set, &1)) do
      nil ->
        :ok

      binding ->
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

  defp binding_referenced?(%Expr{type: :binding, binding: binding}, binding), do: true

  defp binding_referenced?(%Expr{type: :select, source: source}, binding),
    do: binding_referenced?(source, binding)

  defp binding_referenced?(%Expr{type: :shape, data: data}, binding),
    do: binding_referenced?(data, binding)

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

  defp maybe_bind(bindings, nil, _node), do: bindings
  defp maybe_bind(bindings, binding, node), do: Map.put(bindings, binding, node)

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
end
