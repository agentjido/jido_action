defmodule Jido.Exec.Telemetry do
  @moduledoc false

  alias Jido.Exec.Error, as: ExecError
  alias Jido.Flow.Error

  @typedoc false
  @type tracker :: pid() | nil

  @type span :: %{
          owner: pid() | nil,
          parent_id: reference() | nil,
          event: [atom()],
          id: reference(),
          metadata: map(),
          started_at: integer(),
          system_time: integer(),
          tracker: tracker(),
          order: integer()
        }

  @tracker_key {__MODULE__, :tracker}
  @parent_key {__MODULE__, :parent}

  @doc "Creates a random execution correlation identifier."
  @spec execution_id() :: String.t()
  def execution_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc "Starts one telemetry span and returns its local span data."
  @spec start([atom()], map()) :: span()
  def start(event, metadata) do
    started_at = System.monotonic_time()
    tracker = tracker()
    id = make_ref()
    parent_id = parent()

    metadata =
      Map.merge(metadata, %{span_id: id, parent_span_id: parent_id})
      |> Map.put_new(:node_path, [])

    Process.put(@parent_key, id)

    span = %{
      owner: self(),
      event: event,
      id: id,
      parent_id: parent_id,
      metadata: metadata,
      started_at: started_at,
      system_time: System.system_time(),
      tracker: tracker,
      order: :erlang.unique_integer([:monotonic])
    }

    notify(tracker, {:open, span})
    emit_start(span)
    span
  end

  @doc "Stops one telemetry span successfully."
  @spec stop(span()) :: :ok
  def stop(span) do
    emit(span, :stop, %{})
  end

  @doc "Stops one telemetry span with an error."
  @spec error(span(), term()) :: :ok
  def error(span, error) do
    emit(span, :error, error_metadata(error))
  end

  @doc "Stops a span from a result tuple and returns the result unchanged."
  @spec finish(span(), term()) :: term()
  def finish(span, result) do
    case result do
      {:error, error} -> error(span, error)
      {:error, error, _extras} -> error(span, error)
      _success -> stop(span)
    end

    result
  end

  @doc false
  @spec parent() :: reference() | nil
  def parent, do: Process.get(@parent_key)

  @doc false
  @spec with_context(tracker(), reference() | nil, (-> term())) :: term()
  def with_context(tracker, parent, work) do
    prior = Process.put(@parent_key, parent)
    prior_tracker = Process.put(@tracker_key, tracker)

    try do
      work.()
    after
      Process.put(@parent_key, prior)
      Process.put(@tracker_key, prior_tracker)
    end
  end

  @doc false
  @spec detach(span()) :: span()
  def detach(span), do: %{span | owner: nil, tracker: nil, parent_id: nil}

  @doc false
  @spec resume(span()) :: span()
  def resume(span) do
    span = %{
      span
      | owner: self(),
        tracker: tracker(),
        parent_id: Process.put(@parent_key, span.id)
    }

    notify(span.tracker, {:open, span})
    span
  end

  @doc false
  @spec tracker() :: tracker()
  def tracker, do: Process.get(@tracker_key)

  @doc false
  @spec record(map(), {:open, span()} | {:close, reference()}) :: map()
  def record(spans, {:open, span}), do: Map.put(spans, span.id, span)
  def record(spans, {:close, id}), do: Map.delete(spans, id)

  @doc false
  @spec drain(map()) :: map()
  def drain(spans) do
    receive do
      {:telemetry, event} -> drain(record(spans, event))
    after
      0 -> drain_failures(spans)
    end
  end

  defp drain_failures(spans) do
    receive do
      {:worker_error, worker, error} -> drain_failures(fail(spans, error, worker))
    after
      0 -> spans
    end
  end

  @doc false
  @spec fail(map(), term(), pid() | nil) :: map()
  def fail(spans, error, worker \\ nil) do
    {failed, remaining} =
      Enum.split_with(spans, fn {_, span} ->
        is_nil(worker) or span.owner == worker
      end)

    failed
    |> Enum.sort_by(fn {_, span} -> span.order end, :desc)
    |> Enum.each(fn {_, span} -> emit_terminal(span, :error, error_metadata(error)) end)

    Map.new(remaining)
  end

  @doc false
  @spec fail_worker(pid(), pid(), term()) :: term()
  def fail_worker(controller, worker, error), do: send(controller, {:worker_error, worker, error})

  @doc false
  @spec emit_start(span()) :: :ok
  def emit_start(span) do
    :telemetry.execute(
      span.event ++ [:start],
      %{system_time: span.system_time, monotonic_time: span.started_at},
      span.metadata
    )
  end

  @doc false
  @spec emit_terminal(span(), :stop | :error, map()) :: :ok
  @spec emit_terminal(span(), :stop | :error, map(), integer()) :: :ok
  def emit_terminal(span, suffix, extra_metadata, stopped_at \\ System.monotonic_time()) do
    :telemetry.execute(
      span.event ++ [suffix],
      %{duration: stopped_at - span.started_at, monotonic_time: stopped_at},
      Map.merge(span.metadata, extra_metadata)
    )
  end

  @doc false
  @spec error_metadata(term()) :: map()
  def error_metadata(error), do: %{error: error, error_type: error_type(error)}

  defp emit(span, suffix, extra_metadata) do
    notify(span.tracker, {:close, span.id})
    emit_terminal(span, suffix, extra_metadata)
    Process.put(@parent_key, span.parent_id)
    :ok
  end

  defp notify(nil, _event), do: :ok
  defp notify(controller, event), do: send(controller, {:telemetry, event})

  defp error_type(error) when is_exception(error) do
    error_map = if ExecError.owned?(error), do: ExecError.to_map(error), else: Error.to_map(error)
    Map.get(error_map, :type, error.__struct__)
  rescue
    _exception -> error.__struct__
  end

  defp error_type(error), do: error |> value_type()

  defp value_type(value) when is_atom(value), do: value
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(value) when is_list(value), do: :list
  defp value_type(_value), do: :other
end
