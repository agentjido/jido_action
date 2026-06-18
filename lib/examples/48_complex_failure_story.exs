Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, AlwaysFail}
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

fallback = fn _runnable, _error -> {:value, %{recovered: true}} end

flow =
  Flow.new(:complex_failure_story)
  |> Flow.step(:happy_path, Add, params: %{amount: 1})
  |> Flow.step(:optional_path, AlwaysFail)
  |> Flow.step(:fallback_path, AlwaysFail)
  |> Flow.policy(:optional_path, %{on_failure: :skip})
  |> Flow.policy(:fallback_path, %{fallback: fallback})

result = Support.ok!(Exec.run(flow, %{value: 10}))

%{
  happy_path: [%{value: 11}],
  optional_path: [],
  fallback_path: [%{recovered: true}]
} = Exec.results(result)

Support.print("48 complex failure story", Exec.results(result))
