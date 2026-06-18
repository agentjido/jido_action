Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Flaky
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

result =
  Support.with_flaky_key(fn key ->
    flow =
      Flow.new(:retry_transient)
      |> Flow.step(:flaky, Flaky)
      |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

    Support.ok!(Exec.run(flow, %{key: key}))
  end)

%{flaky: [%{attempts: 2}]} = Exec.results(result)

Support.print("21 retry transient failure", Exec.results(result))
