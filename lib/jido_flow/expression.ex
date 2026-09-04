defmodule Jido.Flow.Expression do
  @moduledoc """
  Defines the canonical Flow expression data union.

  An expression is portable literal data, a nested list or map of expressions,
  a `Jido.Flow.Ref`, or a `Jido.Expr` operation. Existing
  `Jido.Flow.Condition` values can also supply Boolean values. This module
  is not an expression wrapper struct.
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
          | Condition.t()

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
  def to_map(%Condition{} = condition), do: Condition.to_map(condition)

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
  def result_refs(%Condition{operands: operands}), do: Enum.flat_map(operands, &result_refs/1)

  def result_refs(%{} = map) do
    map
    |> Map.values()
    |> Enum.flat_map(&result_refs/1)
  end

  def result_refs(list) when is_list(list), do: Enum.flat_map(list, &result_refs/1)
  def result_refs(_value), do: []

  @doc false
  @spec error_kind(Exception.t()) ::
          :invalid_ref_path
          | :invalid_ref
          | :invalid_scope
          | :improper_list
          | :unsupported_expression
          | :other
  def error_kind(%{details: %{ref_type: _type, scope: _scope}}), do: :invalid_scope
  def error_kind(%{details: %{segment: _segment}}), do: :invalid_ref_path
  def error_kind(%{details: %{ref_type: _type}}), do: :invalid_ref
  def error_kind(%{details: %{reason: :improper_list}}), do: :improper_list
  def error_kind(%{details: %{expression: _expression}}), do: :unsupported_expression
  def error_kind(_error), do: :other

  defp do_validate(%Expr{} = expr, path, scope) do
    with :ok <- validate_operation(expr, path) do
      do_validate(expr.operands, path ++ [:operands], scope)
    end
  end

  defp do_validate(%Condition{} = condition, _path, scope) do
    case Condition.validate(condition, scope) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp do_validate(%Ref{} = ref, path, scope) do
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

  defp do_validate(%{} = map, path, scope) when not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      with :ok <- Data.validate_key(key),
           :ok <- do_validate(value, path ++ [key], scope) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, prefix_path(error, path)}}
      end
    end)
  end

  defp do_validate(list, path, scope) when is_list(list) do
    if List.improper?(list) do
      improper_list_error(path)
    else
      validate_proper_list(list, path, scope)
    end
  end

  defp do_validate(%{__struct__: module}, path, _scope) do
    {:error,
     Error.validation_error("flow expression contains an unsupported value", %{
       path: path,
       expression: module
     })}
  end

  defp do_validate(value, path, _scope) do
    case Data.validate(value) do
      :ok -> :ok
      {:error, error} -> {:error, prefix_path(error, path)}
    end
  end

  defp do_normalize(_value, path) when length(path) > 128 do
    {:error, Error.validation_error("Flow expression exceeds max_depth", %{path: path})}
  end

  defp do_normalize(%Expr{} = expr, path) do
    with :ok <- validate_operation(expr, path),
         {:ok, operands} <- do_normalize(expr.operands, path ++ [:operands]) do
      {:ok, %{expr | operands: operands}}
    end
  end

  defp do_normalize(%Condition{} = condition, path) do
    do_normalize(%Expr{operator: condition.operator, operands: condition.operands}, path)
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

  defp validate_proper_list(list, path, scope) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case do_validate(value, path ++ [index], scope) do
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

  defp validate_operation(expr, path) do
    case Expr.validate(expr,
           validate_leaf: fn
             %Ref{} ->
               :ok

             %Condition{} ->
               :ok

             _ ->
               {:error, Error.validation_error("flow expression contains an unsupported value")}
           end
         ) do
      :ok ->
        :ok

      {:error, %Expr.Error{} = error} ->
        {:error,
         Error.validation_error("invalid Flow expression", %{
           path: path ++ error.path,
           operator: error.operator,
           reason: error.reason
         })}

      {:error, error} ->
        {:error, prefix_path(error, path)}
    end
  end
end
