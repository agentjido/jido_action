Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

handler_id = "jido-example-telemetry-#{System.unique_integer([:positive])}"
parent = self()

:ok =
  :telemetry.attach_many(
    handler_id,
    [[:jido, :action, :start], [:jido, :action, :stop]],
    fn event, measurements, metadata, pid ->
      send(pid, {:telemetry_event, event, measurements, metadata})
    end,
    parent
  )

try do
  flow = Flow.from_action(Add, %{amount: 2}, name: :add)
  result = Support.ok!(Exec.run(flow, %{value: 3}, jido: :example))
  %{add: [%{value: 5}]} = Exec.results(result)

  events =
    for _ <- 1..2 do
      receive do
        {:telemetry_event, event, _measurements, metadata} ->
          {event, Map.drop(metadata, [:telemetry_span_context])}
      after
        100 -> raise "missing telemetry event"
      end
    end

  Support.print("49 flow observability telemetry", events)
after
  :telemetry.detach(handler_id)
end
