defmodule Jido.Authoring.Document do
  @moduledoc """
  Enforces resource limits on one complete authoring document.

  `check/1` limits nesting, collection size, and the total number of nodes. It
  does not validate the document owner's fields or the portable value grammar.
  """

  require Jido.Authoring.Limits

  @maximum_depth Jido.Authoring.Limits.maximum_depth()
  @maximum_collection_size Jido.Authoring.Limits.maximum_collection_size()
  @maximum_document_nodes Jido.Authoring.Limits.maximum_document_nodes()
  defmodule Error do
    @moduledoc "An authoring document that exceeds a resource or shape limit."
    defexception [:message, :reason, details: %{}]

    @type reason :: :collection | :depth | :list | :nodes
    @type t :: %__MODULE__{message: String.t(), reason: reason(), details: map()}
  end

  @doc "Checks the resource limits of one complete authoring document."
  @spec check(term()) :: :ok | {:error, Error.t()}
  def check(document) do
    case count(document, 0, @maximum_document_nodes) do
      {:ok, _remaining} -> :ok
      {:error, exception} -> {:error, exception}
    end
  end

  defp count(_value, _depth, remaining) when remaining <= 0,
    do:
      error(:nodes, "authoring document exceeds its total node limit", %{
        maximum_nodes: @maximum_document_nodes
      })

  defp count(_value, depth, _remaining) when depth > @maximum_depth,
    do:
      error(:depth, "authoring document exceeds its nesting limit", %{
        maximum_depth: @maximum_depth
      })

  defp count(value, depth, remaining) when is_list(value) do
    cond do
      List.improper?(value) ->
        error(:list, "authoring document must contain proper lists")

      length(value) > @maximum_collection_size ->
        error(:collection, "authoring document collection exceeds its size limit", %{
          maximum_size: @maximum_collection_size
        })

      true ->
        Enum.reduce_while(value, {:ok, remaining - 1}, fn item, {:ok, left} ->
          case count(item, depth + 1, left) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, exception} -> {:halt, {:error, exception}}
          end
        end)
    end
  end

  defp count(value, depth, remaining) when is_map(value) and not is_struct(value) do
    if map_size(value) > @maximum_collection_size do
      error(:collection, "authoring document collection exceeds its size limit", %{
        maximum_size: @maximum_collection_size
      })
    else
      Enum.reduce_while(value, {:ok, remaining - 1}, fn {key, item}, {:ok, left} ->
        with {:ok, left} <- count(key, depth + 1, left),
             {:ok, left} <- count(item, depth + 1, left) do
          {:cont, {:ok, left}}
        else
          {:error, exception} -> {:halt, {:error, exception}}
        end
      end)
    end
  end

  defp count(_value, _depth, remaining), do: {:ok, remaining - 1}

  defp error(reason, message, details \\ %{}),
    do: {:error, Error.exception(reason: reason, message: message, details: details)}
end
