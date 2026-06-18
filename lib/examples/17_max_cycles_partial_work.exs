Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:max_cycles_partial)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)

partial = Support.error!(Exec.run(flow, %{value: 2}, max_cycles: 1))
:max_cycles = partial.status
%{add: [%{value: 3}]} = Exec.results(partial)

finished = Support.ok!(Exec.resume(partial))
%{double: [%{value: 6}]} = Exec.results(finished)

Support.print("17 max cycles partial work", %{
  partial_status: partial.status,
  finished: Exec.results(finished)
})
