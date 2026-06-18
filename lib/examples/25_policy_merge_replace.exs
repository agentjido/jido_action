Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Flaky
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

merge_result =
  Support.with_flaky_key(fn key ->
    flow =
      Flow.new(:policy_merge)
      |> Flow.step(:flaky, Flaky)
      |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

    Support.ok!(Exec.run(flow, %{key: key}))
  end)

replace_result =
  Support.with_flaky_key(fn key ->
    flow =
      Flow.new(:policy_replace)
      |> Flow.step(:flaky, Flaky)
      |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

    Support.error!(
      Exec.run(flow, %{key: key},
        scheduler_policies: [{:flaky, %{max_retries: 0, backoff: :none}}],
        scheduler_policies_mode: :replace
      )
    )
  end)

%{flaky: [%{attempts: 2}]} = Exec.results(merge_result)
:error = replace_result.status

Support.print("25 policy merge replace", %{
  merge: Exec.results(merge_result),
  replace_status: replace_result.status
})
