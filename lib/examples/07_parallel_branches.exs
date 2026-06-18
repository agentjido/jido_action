Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:parallel_branches)
  |> Flow.step(:plus_one, Add, params: %{amount: 1})
  |> Flow.step(:plus_two, Add, params: %{amount: 2})

result = Support.ok!(Exec.run(flow, %{value: 10}))
%{plus_one: [%{value: 11}], plus_two: [%{value: 12}]} = Exec.results(result)

Support.print("07 parallel branches", Exec.results(result))
