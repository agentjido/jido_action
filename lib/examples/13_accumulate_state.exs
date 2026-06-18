Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:accumulate_state)
  |> Flow.accumulate(:counter, 0, {Functions, :sum})

first = Support.ok!(Exec.run(flow, 2))
second = Support.ok!(Exec.resume(first, 3))

true = 2 in Exec.results(first, raw: true)
true = 5 in Exec.results(second, raw: true)

Support.print("13 accumulate state", %{
  first: Exec.results(first, raw: true),
  second: Exec.results(second, raw: true)
})
