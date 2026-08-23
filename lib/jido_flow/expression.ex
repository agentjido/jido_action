defmodule Jido.Flow.Expression do
  @moduledoc false

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Ref

  @doc false
  @spec normalize(term()) :: {:ok, term()} | {:error, Exception.t()}
  def normalize(expression), do: do_normalize(expression, [])

  @doc false
  @spec validate(term(), Ref.scope()) :: :ok | {:error, Exception.t()}
  def validate(expression, scope \\ :flow), do: do_validate(expression, [], scope)

  @doc false
  @spec to_map(term()) :: term()
  def to_map(%Ref{} = ref), do: Ref.to_map(ref)

  def to_map(%{} = map) do
    Map.new(map, fn {key, value} -> {key, to_map(value)} end)
  end

  def to_map(list) when is_list(list), do: Enum.map(list, &to_map/1)
  def to_map(value), do: Ref.value(value) |> Ref.to_map()

  @doc false
  @spec result_refs(term()) :: [String.t()]
  def result_refs(%Ref{type: :result, node: node}), do: [node]
  def result_refs(%Ref{}), do: []

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
  def error_kind(%{details: %{type: _type}}), do: :invalid_ref
  def error_kind(%{details: %{reason: :improper_list}}), do: :improper_list
  def error_kind(%{details: %{expression: _expression}}), do: :unsupported_expression
  def error_kind(_error), do: :other

  defp do_validate(%Ref{} = ref, path, scope) do
    case Ref.validate(ref, scope) do
      :ok ->
        :ok

      {:error, %{details: %{reason: :path, segment: segment}}} ->
        {:error,
         Error.validation_error("node input contains invalid ref path", %{
           path: path,
           segment: segment
         })}

      {:error, %{details: %{reason: :scope, type: type, scope: invalid_scope}}} ->
        {:error,
         Error.validation_error(
           "flow expression contains a scoped ref outside its valid scope",
           %{path: path, ref_type: type, scope: invalid_scope}
         )}

      {:error, _error} ->
        invalid_ref_error(ref.type, path)
    end
  end

  defp do_validate(%{} = map, path, scope) when not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case do_validate(value, path ++ [key], scope) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
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
     Error.validation_error("node input contains unsupported expression", %{
       path: path,
       expression: module
     })}
  end

  defp do_validate(_value, _path, _scope), do: :ok

  defp do_normalize(%Ref{type: :result, node: node} = ref, _path)
       when (is_atom(node) and not is_nil(node)) or is_binary(node) do
    case normalize_name(node) do
      {:ok, node} -> {:ok, %{ref | node: node}}
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
    {:error, Error.validation_error("node name must be a non-empty string or atom")}
  end

  defp invalid_ref_error(type, path) do
    {:error,
     Error.validation_error("node input contains invalid ref", %{
       path: path,
       type: type
     })}
  end

  defp improper_list_error(path) do
    {:error,
     Error.validation_error("flow expression must be a proper list", %{
       path: path,
       reason: :improper_list
     })}
  end
end
