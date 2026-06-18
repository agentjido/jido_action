Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.AlwaysFail
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

flow =
  Flow.new(:skip_on_failure)
  |> Flow.step(:optional, AlwaysFail)
  |> Flow.policy(:optional, %{on_failure: :skip})

result = Support.ok!(Exec.run(flow, %{}))
:ok = result.status

Support.print("26 skip on failure", %{
  status: result.status,
  results: Exec.results(result),
  events: length(Exec.events(result))
})
