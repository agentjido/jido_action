defmodule Jido.Exec.CollectionTelemetry do
  @moduledoc false

  alias Jido.Action.Telemetry

  @doc false
  def observer(execution_id, flow) when is_binary(execution_id) and is_binary(flow) do
    fn
      {:start, kind, metadata} ->
        {event, telemetry_kind} = event(kind)

        Telemetry.start(
          event,
          Map.merge(metadata, %{
            execution_id: execution_id,
            flow: flow,
            kind: telemetry_kind
          })
        )

      {:stop, span} ->
        Telemetry.stop(span)

      {:error, span, error} ->
        Telemetry.error(span, error)
    end
  end

  defp event(:map_item), do: {[:jido, :flow, :map, :item], :map_item}
  defp event(:reduce_item), do: {[:jido, :flow, :reduce, :item], :reduce_item}

  defp event(:iterate_iteration),
    do: {[:jido, :flow, :iterate, :iteration], :iterate_iteration}
end
