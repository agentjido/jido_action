Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, SumJoined}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:fan_in_join)
  |> Flow.step(:plus_one, Add, params: %{amount: 1})
  |> Flow.step(:plus_two, Add, params: %{amount: 2})
  |> Flow.step(:sum, SumJoined, after: [:plus_one, :plus_two])

result = Support.ok!(Exec.run(flow, %{value: 10}))
%{sum: [%{value: 23}]} = Exec.results(result)

Support.print("08 fan-in join", Exec.results(result))
