Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double, EnrichTenant, SumJoined}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:validation_enrichment)
  |> Flow.step(:enrich, EnrichTenant)
  |> Flow.step(:add_check, Add, params: %{amount: 1}, after: :enrich)
  |> Flow.step(:double_check, Double, after: :enrich)
  |> Flow.step(:decision, SumJoined, after: [:add_check, :double_check])

result =
  Support.ok!(Exec.run(flow, %{value: 4}, run_context: %{tenant: "tenant_123"}))

%{decision: [%{value: 13}]} = Exec.results(result)

Support.print("42 validation enrichment pipeline", Exec.results(result))
