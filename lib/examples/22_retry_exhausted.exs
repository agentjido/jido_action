Code.require_file("support.exs", __DIR__)

alias Jido.Action.Error
alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Flaky
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

result =
  Support.with_flaky_key(fn key ->
    flow =
      Flow.new(:retry_exhausted)
      |> Flow.step(:flaky, Flaky)
      |> Flow.policy(:flaky, %{max_retries: 0, backoff: :none})

    Support.error!(Exec.run(flow, %{key: key}))
  end)

:error = result.status
%{type: :execution_error} = error = Error.to_map(result.error)

Support.print("22 retry exhausted", %{status: result.status, error: error})
