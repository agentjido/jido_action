defmodule Jido.Exec.Telemetry do
  @moduledoc """
  Telemetry functionality for Jido.Exec.
  
  This module handles:
  - Telemetry event emission
  - Span management (start/end)
  - Metadata collection for telemetry events
  - Process information gathering
  """

  @type action :: module()
  @type params :: map()
  @type context :: map()

  @spec start_span(action(), params(), context(), atom()) :: :ok
  def start_span(action, params, context, telemetry) do
    metadata = %{
      action: action,
      params: params,
      context: context
    }

    emit_telemetry_event(:start, metadata, telemetry)
  end

  @spec end_span(action(), {:ok, map()} | {:error, any()}, non_neg_integer(), atom()) :: :ok
  def end_span(action, result, duration_us, telemetry) do
    metadata = get_metadata(action, result, duration_us, telemetry)

    status =
      case result do
        {:ok, _} -> :complete
        {:ok, _, _} -> :complete
        _ -> :error
      end

    emit_telemetry_event(status, metadata, telemetry)
  end

  @spec get_metadata(action(), {:ok, map()} | {:error, any()}, non_neg_integer(), atom()) :: map()
  def get_metadata(action, result, duration_us, :full) do
    %{
      action: action,
      result: result,
      duration_us: duration_us,
      memory_usage: :erlang.memory(),
      process_info: get_process_info(),
      node: node()
    }
  end

  def get_metadata(action, result, duration_us, :minimal) do
    %{
      action: action,
      result: result,
      duration_us: duration_us
    }
  end

  @spec get_process_info() :: map()
  def get_process_info do
    for key <- [:reductions, :message_queue_len, :total_heap_size, :garbage_collection],
        into: %{} do
      {key, self() |> Process.info(key) |> elem(1)}
    end
  end

  @spec emit_telemetry_event(atom(), map(), atom()) :: :ok
  def emit_telemetry_event(event, metadata, telemetry) when telemetry in [:full, :minimal] do
    event_name = [:jido, :action, event]
    measurements = %{system_time: System.system_time()}

    :telemetry.execute(event_name, measurements, metadata)
  end

  def emit_telemetry_event(_, _, _), do: :ok
end
