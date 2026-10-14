defmodule Jido.Flow.Codec.Limits do
  @moduledoc false
  alias Jido.Flow.Error
  @maximum_depth 100
  @maximum_collection_size 10_000
  @maximum_document_nodes 100_000

  @doc false
  @spec depth(non_neg_integer()) :: :ok | {:error, Exception.t()}
  def depth(value) when value <= @maximum_depth, do: :ok

  def depth(_value),
    do:
      {:error,
       Error.validation_error("stored Flow exceeds its nesting limit", %{
         maximum_depth: @maximum_depth
       })}

  @doc false
  @spec size(term()) :: :ok | {:error, Exception.t()}
  def size(values) when length(values) <= @maximum_collection_size, do: :ok

  def size(values)
      when is_map(values) and map_size(values) <= @maximum_collection_size,
      do: :ok

  def size(_values),
    do:
      {:error,
       Error.validation_error("stored Flow collection exceeds its size limit", %{
         maximum_size: @maximum_collection_size
       })}

  @doc false
  @spec check(term()) :: :ok | {:error, Exception.t()}
  def check(document) do
    case count_document_nodes(document, 0, @maximum_document_nodes) do
      {:ok, _remaining} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp count_document_nodes(_value, _depth, remaining) when remaining <= 0 do
    {:error,
     Error.validation_error("stored Flow exceeds its total node limit", %{
       maximum_nodes: @maximum_document_nodes
     })}
  end

  defp count_document_nodes(value, depth, remaining) when is_list(value) do
    with :ok <- depth(depth),
         false <- List.improper?(value),
         :ok <- size(value) do
      Enum.reduce_while(value, {:ok, remaining - 1}, fn item, {:ok, remaining} ->
        case count_document_nodes(item, depth + 1, remaining) do
          {:ok, remaining} -> {:cont, {:ok, remaining}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    else
      true ->
        {:error, Error.validation_error("stored Flow data must contain proper lists")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp count_document_nodes(value, depth, remaining)
       when is_map(value) and not is_struct(value) do
    with :ok <- depth(depth),
         :ok <- document_map_size(value) do
      Enum.reduce_while(value, {:ok, remaining - 1}, fn {key, item}, {:ok, remaining} ->
        with {:ok, remaining} <- count_document_nodes(key, depth + 1, remaining),
             {:ok, remaining} <- count_document_nodes(item, depth + 1, remaining) do
          {:cont, {:ok, remaining}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp count_document_nodes(_value, depth, remaining) do
    with :ok <- depth(depth), do: {:ok, remaining - 1}
  end

  defp document_map_size(value) when map_size(value) <= @maximum_collection_size, do: :ok

  defp document_map_size(_value) do
    {:error,
     Error.validation_error("stored Flow collection exceeds its size limit", %{
       maximum_size: @maximum_collection_size
     })}
  end
end
