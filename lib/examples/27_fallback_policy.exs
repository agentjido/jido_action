Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.AlwaysFail
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

fallback = fn _runnable, _error -> {:value, %{recovered: true}} end

flow =
  Flow.new(:fallback_policy)
  |> Flow.step(:unstable, AlwaysFail)
  |> Flow.policy(:unstable, %{fallback: fallback})

result = Support.ok!(Exec.run(flow, %{}))
%{unstable: [%{recovered: true}]} = Exec.results(result)

Support.print("27 fallback policy", Exec.results(result))
