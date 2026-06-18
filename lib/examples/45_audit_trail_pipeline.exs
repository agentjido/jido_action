Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, DirectiveAction}
alias Jido.Examples.Support
alias Runic.Workflow

Support.ensure!()

flow =
  Flow.new(:audit_trail)
  |> Flow.step(:directive, DirectiveAction)
  |> Flow.step(:add, Add, params: %{amount: 5}, after: :directive)

result = Support.ok!(Exec.run(flow, %{value: 2}))
%{add: [%{value: 7}]} = Exec.results(result)
[%{directives: %{route: :next}}] = result.directives

final_fact =
  result.workflow
  |> Workflow.facts()
  |> Enum.find(fn fact -> fact.value == %{value: 7} end)

{:ok, provenance} = Exec.provenance(result, final_fact.hash)

Support.print(
  "45 audit trail pipeline",
  %{
    events: length(Exec.events(result)),
    directives: result.directives,
    provenance: Enum.map(provenance, & &1.value)
  }
)
