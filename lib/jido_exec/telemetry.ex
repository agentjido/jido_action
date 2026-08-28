defmodule Jido.Exec.Telemetry do
  @moduledoc false

  alias Jido.Exec.Error, as: ExecError
  alias Jido.Flow.Error

  @type span :: %{
          event: [atom()],
          id: reference(),
          metadata: map(),
          started_at: integer(),
          tracker: pid() | nil,
          tracked?: boolean()
        }

  @tracker_key {__MODULE__, :tracker}

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

    span = %{
      event: event,
      id: make_ref(),
      metadata: metadata,
      started_at: started_at,
      tracker: tracker,
      tracked?: false
    }

    case tracker do
      nil ->
        emit_start(span)
        %{span | tracked?: true}

      tracker ->
        case Jido.Exec.Telemetry.Tracker.open(tracker, span) do
          :ok -> %{span | tracked?: true}
          :suppressed -> span
        end
    end
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
  @spec tracker() :: pid() | nil
  def tracker, do: Process.get(@tracker_key)

  @doc false
  @spec put_tracker(pid() | nil) :: pid() | nil
  def put_tracker(tracker) when is_pid(tracker) or is_nil(tracker) do
    Process.put(@tracker_key, tracker)
  end

  @doc false
  @spec with_tracker(pid(), (-> result)) :: result when result: term()
  def with_tracker(tracker, fun) when is_pid(tracker) and is_function(fun, 0) do
    prior = put_tracker(tracker)

    try do
      fun.()
    after
      put_tracker(prior)
    end
  end

  @doc false
  @spec emit_start(span()) :: :ok
  def emit_start(span) do
    :telemetry.execute(
      span.event ++ [:start],
      %{system_time: System.system_time(), monotonic_time: span.started_at},
      span.metadata
    )
  end

  @doc false
  @spec emit_terminal(span(), :stop | :error, map()) :: :ok
  def emit_terminal(span, suffix, extra_metadata) do
    stopped_at = System.monotonic_time()

    :telemetry.execute(
      span.event ++ [suffix],
      %{duration: stopped_at - span.started_at, monotonic_time: stopped_at},
      Map.merge(span.metadata, extra_metadata)
    )
  end

  @doc false
  @spec error_metadata(term()) :: map()
  def error_metadata(error), do: %{error: error, error_type: error_type(error)}

  defp emit(%{tracked?: false}, _suffix, _extra_metadata), do: :ok

  defp emit(%{tracker: nil} = span, suffix, extra_metadata) do
    emit_terminal(span, suffix, extra_metadata)
  end

  defp emit(%{tracker: tracker} = span, suffix, extra_metadata) do
    Jido.Exec.Telemetry.Tracker.close(tracker, span, suffix, extra_metadata)
  end

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
