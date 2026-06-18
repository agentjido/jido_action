Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.CountInput
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:actions_plus_primitives)
  |> Flow.step(:count, CountInput)
  |> Flow.map(:double_each, {Functions, :double})
  |> Flow.reduce(:sum, 0, {Functions, :sum}, after: :double_each, map: :double_each)

result = Support.ok!(Exec.run(flow, [1, 2, 3]))
%{count: [%{count: 3}]} = Exec.results(result)
true = 12 in Exec.results(result, raw: true)

Support.print("14 actions plus primitives", Exec.results(result))
