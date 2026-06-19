Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, DirectiveAction}
alias Jido.Examples.Support
alias Runic.Workflow

Support.ensure!()

flow =
  Flow.new(:end_to_end)
  |> Flow.step(:directive, DirectiveAction)
  |> Flow.step(:add, Add, params: %{amount: 4}, after: :directive)
  |> Flow.policy(:add, %{execution_mode: :durable})

ir = Flow.to_map(flow)
round_trip = Flow.new(ir)
true = Flow.to_map(round_trip) == ir

result = Support.ok!(Exec.run(round_trip, %{value: 6}, jido: :example))

%{add: [%{value: 10}]} = Exec.results(result)
[%{directives: %{route: :next}}] = result.directives

final_fact =
  result.workflow
  |> Workflow.facts()
  |> Enum.find(fn fact -> fact.value == %{value: 10} end)

{:ok, provenance} = Exec.provenance(result, final_fact.hash)

Support.print(
  "50 end-to-end spike",
  %{
    ir: ir,
    round_trip?: Flow.to_map(round_trip) == ir,
    results: Exec.results(result),
    directives: result.directives,
    events: length(Exec.events(result)),
    provenance: Enum.map(provenance, & &1.value)
  }
)
