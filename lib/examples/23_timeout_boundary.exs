Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Slow
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

flow =
  Flow.new(:timeout_boundary)
  |> Flow.step(:slow, Slow, params: %{delay: 50})
  |> Flow.policy(:slow, %{timeout_ms: 5, max_retries: 0, backoff: :none})

result = Support.error!(Exec.run(flow, %{}))
:error = result.status
{:timeout, 5} = result.error.details.reason

Support.print("23 timeout boundary", %{status: result.status, reason: result.error.details.reason})
