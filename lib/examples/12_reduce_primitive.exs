Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:reduce_primitive)
  |> Flow.reduce(:sum, 0, {Functions, :sum})

result = Support.ok!(Exec.run(flow, [1, 2, 3, 4]))
true = 10 in Exec.results(result, raw: true)

Support.print("12 reduce primitive", Exec.results(result, raw: true))
