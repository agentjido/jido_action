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
          bindings: %{atom() => Ref.t()},
          seen: MapSet.t(atom()),
          return: Ref.t() | nil
        }

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
    initial_state = %{nodes: [], bindings: %{}, seen: MapSet.new(), return: nil}

    Enum.reduce_while(operations, {:ok, initial_state}, fn operation, {:ok, state} ->
      case lower_operation(operation, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp lower_operation(%Operation{kind: :step, attrs: attrs}, state) do
    step_name = Map.get(attrs, :name)

    with {:ok, input} <- resolve_expr(Map.get(attrs, :input, %{}), state, step_name),
         {:ok, node} <-
           Node.new(
             name: step_name,
             action: Map.get(attrs, :action),
             input: input,
             provenance: Map.get(attrs, :provenance, %{})
           ),
         {:ok, bindings} <-
           maybe_bind(Map.get(attrs, :bind), Ref.result(node.name), state.bindings) do
      {:ok,
       %{
         state
         | nodes: [node | state.nodes],
           bindings: bindings,
           seen: MapSet.put(state.seen, node.name)
       }}
    end
  end

  defp lower_operation(%Operation{kind: :bind, attrs: attrs}, state) do
    with {:ok, ref} <- resolve_expr(Map.get(attrs, :expr), state, nil),
         {:ok, bindings} <- bind_result(Map.get(attrs, :name), ref, state.bindings) do
      {:ok, %{state | bindings: bindings}}
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

  defp resolve_expr(%Expr{type: :var, name: name, path: path}, state, step) do
    case Map.fetch(state.bindings, name) do
      {:ok, %Ref{type: :result, node: node, path: base_path}} ->
        resolve_expr(%Expr{type: :result, node: node, path: base_path ++ path}, state, step)

      :error ->
        {:error,
         Error.validation_error("unknown flow variable binding: #{inspect(name)}", %{
           step: step,
           binding: name
         })}
    end
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

  defp maybe_bind(nil, _ref, bindings), do: {:ok, bindings}
  defp maybe_bind(name, ref, bindings), do: bind_result(name, ref, bindings)

  defp bind_result(name, %Ref{type: :result} = ref, bindings)
       when is_atom(name) and not is_nil(name) do
    {:ok, Map.put(bindings, name, ref)}
  end

  defp bind_result(name, %Ref{}, _bindings) when is_atom(name) and not is_nil(name) do
    {:error, Error.validation_error("flow variable bindings must point to result refs")}
  end

  defp bind_result(_name, _ref, _bindings) do
    {:error, Error.validation_error("flow variable binding name must be a non-nil atom")}
  end

  defp validate_return_ref(%Ref{type: :result} = ref), do: {:ok, ref}

  defp validate_return_ref(_ref) do
    {:error, Error.validation_error("return must resolve to a result ref")}
  end

  defp require_return(nil) do
    {:error, Error.validation_error("return ref is required", %{operation: :return})}
  end

  defp require_return(%Ref{} = ref), do: {:ok, ref}

  defp result_before_bound_error(step, dependency) do
    {:error,
     Error.validation_error("result reference before it is bound: #{inspect(dependency)}", %{
       step: step,
       dependency: dependency
     })}
  end
end
