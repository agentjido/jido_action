defmodule Jido.Flow.MapCodec.IteratorDecoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.DataDecoder
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.ExpressionDecoder
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.MapCodec.RegistryLookup

  @doc false
  def decode(iterator) do
    with :ok <- RecordValidator.validate_iterator_record(iterator),
         {:ok, name} <-
           RecordValidator.fetch_required(iterator, :name, "iterator name is required"),
         {:ok, action} <-
           RecordValidator.fetch_required(iterator, :action, "iterator action is required"),
         {:ok, action} <-
           RegistryLookup.decode_identifier(action, :action)
           |> ErrorPath.prepend([RecordValidator.field(:action)]),
         {:ok, input} <-
           RecordValidator.fetch_required(iterator, :input, "iterator input is required"),
         {:ok, input} <-
           ExpressionDecoder.decode(input)
           |> ErrorPath.prepend([RecordValidator.field(:input)]),
         {:ok, state} <-
           RecordValidator.fetch_required(iterator, :state, "iterator state is required"),
         {:ok, state} <-
           decode_state(state)
           |> ErrorPath.prepend([RecordValidator.field(:state)]),
         {:ok, completion} <-
           RecordValidator.fetch_required(
             iterator,
             :completion,
             "iterator completion is required"
           ),
         {:ok, completion} <-
           ExpressionDecoder.decode_condition(completion, :iterate_completion)
           |> ErrorPath.prepend([RecordValidator.field(:completion)]),
         {:ok, max_iterations} <-
           RecordValidator.fetch_required(
             iterator,
             :max_iterations,
             "iterator max_iterations is required"
           ),
         {:ok, deps} <-
           RecordValidator.fetch_required(iterator, :deps, "iterator deps are required"),
         {:ok, deps} <- RecordValidator.validate_node_deps(deps),
         {:ok, provenance} <-
           DataDecoder.decode_optional(iterator, :provenance, %{})
           |> ErrorPath.prepend([RecordValidator.field(:provenance)]) do
      {:ok,
       %{
         kind: :iterate,
         name: name,
         action: action,
         input: input,
         state: state,
         completion: completion,
         max_iterations: max_iterations,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp decode_state(%{} = state) do
    with :ok <- RecordValidator.validate_iterator_state_record(state),
         :ok <-
           validate_state_kind(RecordValidator.fetch_optional(state, :kind, nil)),
         {:ok, version} <-
           RecordValidator.fetch_required(state, :version, "iterator state version is required"),
         :ok <- validate_state_version(version),
         {:ok, schema} <-
           RecordValidator.fetch_required(state, :schema, "iterator state schema is required"),
         {:ok, schema} <- RegistryLookup.decode_identifier(schema, :schema),
         {:ok, initial} <-
           RecordValidator.fetch_required(state, :initial, "iterator state initial is required"),
         {:ok, initial} <-
           ExpressionDecoder.decode(initial)
           |> ErrorPath.prepend([RecordValidator.field(:initial)]),
         {:ok, update} <-
           RecordValidator.fetch_required(state, :update, "iterator state update is required"),
         {:ok, update} <-
           ExpressionDecoder.decode(update)
           |> ErrorPath.prepend([RecordValidator.field(:update)]) do
      {:ok, %{version: version, schema: schema, initial: initial, update: update}}
    end
  end

  defp decode_state(_state), do: ErrorPath.error("iterator state must be a map")

  defp validate_state_version(1), do: :ok

  defp validate_state_version(version) do
    ErrorPath.error("unsupported iterator state version: #{inspect(version)}", %{version: version})
  end

  defp validate_state_kind("iterate_state"), do: :ok

  defp validate_state_kind(kind) do
    ErrorPath.error("iterate state kind must be iterate_state", %{kind: kind})
  end
end
