Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Slow}
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

flow =
  Flow.new(:deadline_across_flow)
  |> Flow.step(:slow, Slow, params: %{delay: 30})
  |> Flow.step(:add, Add, params: %{amount: 1}, after: :slow)

result = Support.error!(Exec.run(flow, %{}, deadline_ms: 5))
:error = result.status

Support.print("24 deadline across flow", %{
  status: result.status,
  reason: result.error.details.reason
})
