Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:partial_ui_model)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)
  |> Flow.step(:add_again, Add, params: %{amount: 3}, after: :double)

first_cycle = Support.ok!(Exec.step(flow, %{value: 2}))
%{add: [%{value: 3}]} = Exec.results(first_cycle)

finished = Support.ok!(Exec.resume(first_cycle))
%{add_again: [%{value: 9}]} = Exec.results(finished)

Support.print(
  "46 partial execution UI model",
  %{
    graph: Flow.graph(flow),
    first_cycle: Exec.results(first_cycle),
    finished: Exec.results(finished)
  }
)
