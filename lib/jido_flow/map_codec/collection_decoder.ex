defmodule Jido.Flow.MapCodec.CollectionDecoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.DataCodec
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.ExpressionCodec
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.MapCodec.RegistryLookup

  @doc false
  def decode_map(map) do
    with :ok <- RecordValidator.validate_map_record(map),
         {:ok, name} <- RecordValidator.fetch_required(map, :name, "map name is required"),
         {:ok, collection} <-
           RecordValidator.fetch_required(map, :collection, "map collection is required"),
         {:ok, collection} <-
           ExpressionCodec.decode(collection)
           |> ErrorPath.prepend([RecordValidator.field(:collection)]),
         {:ok, action} <-
           RecordValidator.fetch_required(map, :action, "map action is required"),
         {:ok, action} <-
           RegistryLookup.decode_identifier(action, :action)
           |> ErrorPath.prepend([RecordValidator.field(:action)]),
         {:ok, input} <-
           RecordValidator.fetch_required(map, :input, "map input is required"),
         {:ok, input} <-
           ExpressionCodec.decode(input)
           |> ErrorPath.prepend([RecordValidator.field(:input)]),
         {:ok, on_error} <-
           RecordValidator.fetch_required(map, :on_error, "map on_error is required"),
         {:ok, on_error} <-
           decode_map_error_mode(on_error)
           |> ErrorPath.prepend([RecordValidator.field(:on_error)]),
         {:ok, deps} <- RecordValidator.fetch_required(map, :deps, "map deps are required"),
         {:ok, deps} <- RecordValidator.validate_node_deps(deps),
         {:ok, provenance} <-
           DataCodec.decode_optional(map, :provenance, %{})
           |> ErrorPath.prepend([RecordValidator.field(:provenance)]) do
      {:ok,
       %{
         kind: :map,
         name: name,
         collection: collection,
         action: action,
         input: input,
         on_error: on_error,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  @doc false
  def decode_reduce(reduce) do
    with :ok <- RecordValidator.validate_reduce_record(reduce),
         {:ok, name} <-
           RecordValidator.fetch_required(reduce, :name, "reduce name is required"),
         {:ok, collection} <-
           RecordValidator.fetch_required(
             reduce,
             :collection,
             "reduce collection is required"
           ),
         {:ok, collection} <-
           ExpressionCodec.decode(collection)
           |> ErrorPath.prepend([RecordValidator.field(:collection)]),
         {:ok, initial} <-
           RecordValidator.fetch_required(reduce, :initial, "reduce initial is required"),
         {:ok, initial} <-
           ExpressionCodec.decode(initial)
           |> ErrorPath.prepend([RecordValidator.field(:initial)]),
         {:ok, action} <-
           RecordValidator.fetch_required(reduce, :action, "reduce action is required"),
         {:ok, action} <-
           RegistryLookup.decode_identifier(action, :action)
           |> ErrorPath.prepend([RecordValidator.field(:action)]),
         {:ok, input} <-
           RecordValidator.fetch_required(reduce, :input, "reduce input is required"),
         {:ok, input} <-
           ExpressionCodec.decode(input)
           |> ErrorPath.prepend([RecordValidator.field(:input)]),
         {:ok, deps} <-
           RecordValidator.fetch_required(reduce, :deps, "reduce deps are required"),
         {:ok, deps} <- RecordValidator.validate_node_deps(deps),
         {:ok, provenance} <-
           DataCodec.decode_optional(reduce, :provenance, %{})
           |> ErrorPath.prepend([RecordValidator.field(:provenance)]) do
      {:ok,
       %{
         kind: :reduce,
         name: name,
         collection: collection,
         initial: initial,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp decode_map_error_mode("fail_fast"), do: {:ok, :fail_fast}
  defp decode_map_error_mode("collect_errors"), do: {:ok, :collect_errors}

  defp decode_map_error_mode(mode) do
    ErrorPath.error("map on_error must be fail_fast or collect_errors", %{on_error: mode})
  end
end
