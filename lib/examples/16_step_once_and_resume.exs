Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:step_once)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)

partial = Support.ok!(Exec.step(flow, %{value: 2}))
%{add: [%{value: 3}]} = Exec.results(partial)

finished = Support.ok!(Exec.resume(partial))
%{double: [%{value: 6}]} = Exec.results(finished)

Support.print("16 step once and resume", %{
  partial: Exec.results(partial),
  finished: Exec.results(finished)
})
