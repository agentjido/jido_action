defmodule Jido.Exec.Portable do
  @moduledoc false

  alias Jido.Action.Error

  @spec validate(term(), atom()) :: :ok | {:error, Exception.t()}
  def validate(value, field) do
    case walk(value, [field]) do
      :ok ->
        :ok

      {:error, type, path} ->
        {:error,
         Error.execution_error("durable execution data contains a process-local value", %{
           phase: :durability,
           reason: :non_portable_durable_value,
           type: type,
           path: path,
           retry: false
         })}
    end
  end

  defp walk(value, path) when is_pid(value), do: {:error, :pid, path}
  defp walk(value, path) when is_port(value), do: {:error, :port, path}
  defp walk(value, path) when is_reference(value), do: {:error, :reference, path}
  defp walk(value, path) when is_function(value), do: {:error, :function, path}

  defp walk(value, path) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.reduce_while(:ok, fn {key, item}, :ok ->
      case walk(key, path ++ [:key]) do
        :ok -> continue(item, path ++ [key])
        {:error, _type, _path} = error -> {:halt, error}
      end
    end)
  end

  defp walk(value, path) when is_list(value), do: walk_list(value, path, 0)

  defp walk(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok -> continue(item, path ++ [index]) end)
  end

  defp walk(_value, _path), do: :ok

  defp walk_list([], _path, _index), do: :ok

  defp walk_list([item | rest], path, index) do
    case walk(item, path ++ [index]) do
      :ok when is_list(rest) -> walk_list(rest, path, index + 1)
      :ok -> walk(rest, path ++ [:tail])
      {:error, _type, _path} = error -> error
    end
  end

  defp continue(value, path) do
    case walk(value, path) do
      :ok -> {:cont, :ok}
      {:error, _type, _path} = error -> {:halt, error}
    end
  end
end
