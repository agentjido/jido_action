Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support
alias Runic.Workflow

Support.ensure!()

flow =
  Flow.new(:events_and_provenance)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)

result = Support.ok!(Exec.run(flow, %{value: 2}))

final_fact =
  result.workflow
  |> Workflow.facts()
  |> Enum.find(fn fact -> fact.value == %{value: 6} end)

{:ok, chain} = Exec.provenance(result, final_fact.hash)
[%{value: 2}, %{value: 3}, %{value: 6}] = Enum.map(chain, & &1.value)

Support.print("19 events and provenance", %{
  events: length(Exec.events(result)),
  provenance: Enum.map(chain, & &1.value)
})
