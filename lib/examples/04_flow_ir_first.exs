Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:ir_first)
  |> Flow.step(:add, Add, params: %{amount: 2})
  |> Flow.step(:double, Double, after: :add)

ir = Flow.to_map(flow)
result = Support.ok!(Exec.run(flow, %{value: 3}))
%{double: [%{value: 10}]} = Exec.results(result)

Support.print("04 flow IR first", %{ir: ir, results: Exec.results(result)})
