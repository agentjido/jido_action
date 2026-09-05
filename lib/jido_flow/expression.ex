defmodule Jido.Flow.Expression do
  @moduledoc """
  Defines the canonical Flow expression data union.

  An expression is portable literal data, a nested list or map of expressions,
  a `Jido.Flow.Ref`, or a `Jido.Expr` operation. Legacy
  `Jido.Flow.Condition` input is converted to Expr at construction.
  This module is not an expression wrapper struct.
  """

  alias Jido.Action
  alias Jido.Expr
  alias Jido.Flow.Condition
  alias Jido.Flow.Error
  alias Jido.Flow.Data
  alias Jido.Flow.Ref

  @typedoc "Canonical portable expression data."
  @type t ::
          Data.scalar()
          | [t()]
          | %{optional(Data.key()) => t()}
          | Ref.t()
          | Expr.t()

  @doc false
  @spec normalize(term()) :: {:ok, term()} | {:error, Exception.t()}
  def normalize(expression), do: do_normalize(expression, [])

  @doc false
  @spec validate(term(), Ref.scope()) :: :ok | {:error, Exception.t()}
  def validate(expression, scope \\ :flow), do: do_validate(expression, [], scope)

  @doc false
  @spec to_map(term()) :: term()
  def to_map(%Ref{} = ref), do: Ref.to_map(ref)

  # Keep the struct tag distinct from a literal map with operator fields.
  def to_map(%Expr{} = expr), do: %{expr | operands: Enum.map(expr.operands, &to_map/1)}

  def to_map(%{} = map) do
    Map.new(map, fn {key, value} -> {key, to_map(value)} end)
  end

  def to_map(list) when is_list(list), do: Enum.map(list, &to_map/1)
  def to_map(value), do: value

  @doc false
  @spec result_refs(term()) :: [String.t()]
  def result_refs(%Ref{source: :result, component: component}), do: [component]
  def result_refs(%Ref{}), do: []
  def result_refs(%Expr{operands: operands}), do: Enum.flat_map(operands, &result_refs/1)

  def result_refs(%{} = map) do
    map
    |> Map.values()
    |> Enum.flat_map(&result_refs/1)
  end

  def result_refs(list) when is_list(list), do: Enum.flat_map(list, &result_refs/1)
  def result_refs(_value), do: []

  defp do_validate(value, path, scope, operation_checked? \\ false)

  defp do_validate(%Expr{} = expr, path, scope, operation_checked?) do
    # Check the complete operation budget once. The following host-data walk
    # checks Flow keys, UTF-8, and reference scope without subtree revalidation.
    with :ok <- validate_operation(expr, path, operation_checked?) do
      do_validate(expr.operands, path ++ [:operands], scope, true)
    end
  end

  defp do_validate(%Ref{} = ref, path, scope, _operation_checked?) do
    case Ref.validate(ref, scope) do
      :ok ->
        :ok

      {:error, %{details: %{reason: :path, segment: segment}}} ->
        {:error,
         Error.validation_error("flow expression contains an invalid reference path", %{
           path: path,
           segment: segment
         })}

      {:error, %{details: %{reason: :scope, source: type, scope: invalid_scope}}} ->
        {:error,
         Error.validation_error(
           "flow expression contains a scoped ref outside its valid scope",
           %{path: path, ref_type: type, scope: invalid_scope}
         )}

      {:error, _error} ->
        invalid_ref_error(ref.source, path)
    end
  end

  defp do_validate(%{} = map, path, scope, operation_checked?) when not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case Data.validate_key(key) do
        :ok ->
          case do_validate(value, path ++ [key], scope, operation_checked?) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end

        {:error, error} ->
          {:halt, {:error, prefix_path(error, path)}}
      end
    end)
  end

  defp do_validate(list, path, scope, operation_checked?) when is_list(list) do
    if List.improper?(list) do
      improper_list_error(path)
    else
      validate_proper_list(list, path, scope, operation_checked?)
    end
  end

  defp do_validate(%{__struct__: module}, path, _scope, _operation_checked?) do
    {:error,
     Error.validation_error("flow expression contains an unsupported value", %{
       path: path,
       expression: module
     })}
  end

  defp do_validate(value, path, _scope, _operation_checked?) do
    case Data.validate(value) do
      :ok -> :ok
      {:error, error} -> {:error, prefix_path(error, path)}
    end
  end

  defp validate_operation(_expr, _path, true), do: :ok

  defp validate_operation(expr, path, false) do
    expr
    |> Expr.validate(validate_leaf: fn _ -> :ok end)
    |> operation_result(path)
  end

  defp do_normalize(expression, path)
       when is_struct(expression, Expr) or is_struct(expression, Condition) do
    expression
    |> Jido.Expr.Runtime.normalize(
      normalize_leaf: &normalize_leaf/2,
      validate_leaf: &do_validate(&1, &2, :any)
    )
    |> operation_result(path)
  end

  defp do_normalize(%Ref{source: :result, component: component} = ref, _path)
       when (is_atom(component) and not is_nil(component)) or is_binary(component) do
    case normalize_name(component) do
      {:ok, component} -> {:ok, %{ref | component: component}}
      {:error, error} -> {:error, error}
    end
  end

  defp do_normalize(%Ref{} = ref, _path), do: {:ok, ref}

  defp do_normalize(%{} = map, path) when not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case do_normalize(value, path ++ [key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp do_normalize(list, path) when is_list(list) do
    if List.improper?(list) do
      improper_list_error(path)
    else
      normalize_proper_list(list, path)
    end
  end

  defp do_normalize(value, _path), do: {:ok, value}

  defp normalize_leaf(%Condition{} = condition, path) do
    case Condition.to_expr(condition) do
      {:ok, expression} -> {:ok, expression}
      {:error, error} -> {:error, prefix_path(error, path)}
    end
  end

  defp normalize_leaf(value, path), do: do_normalize(value, path)

  defp validate_proper_list(list, path, scope, operation_checked?) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case do_validate(value, path ++ [index], scope, operation_checked?) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_proper_list(list, path) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case do_normalize(value, path ++ [index]) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_name(name) when is_atom(name) and not is_nil(name) do
    name |> Atom.to_string() |> normalize_name()
  end

  defp normalize_name(name) when is_binary(name) do
    case Action.validate_name(name) do
      :ok -> {:ok, name}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  defp normalize_name(_name) do
    {:error, Error.validation_error("component name must be a non-empty string or atom")}
  end

  defp invalid_ref_error(type, path) do
    {:error,
     Error.validation_error("flow expression contains an invalid reference", %{
       path: path,
       ref_type: type
     })}
  end

  defp improper_list_error(path) do
    {:error,
     Error.validation_error("flow expression must be a proper list", %{
       path: path,
       reason: :improper_list
     })}
  end

  defp prefix_path(%{details: details} = error, path) when is_map(details) do
    %{error | details: Map.put(details, :path, path ++ Map.get(details, :path, []))}
  end

  defp prefix_path(error, _path), do: error

  defp operation_result({:error, %Expr.Error{} = error}, path) do
    {:error,
     Error.validation_error("invalid Flow expression", %{
       path: path ++ error.path,
       operator: error.operator,
       reason: error.reason
     })}
  end

  defp operation_result({:error, error}, path), do: {:error, prefix_path(error, path)}
  defp operation_result(result, _path), do: result
end
