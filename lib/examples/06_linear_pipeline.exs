Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:linear_pipeline)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)
  |> Flow.step(:add_again, Add, params: %{amount: 3}, after: :double)

result = Support.ok!(Exec.run(flow, %{value: 2}))
%{add_again: [%{value: 9}]} = Exec.results(result)

Support.print("06 linear pipeline", Exec.results(result))
