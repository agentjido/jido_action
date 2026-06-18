Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

flow = Flow.from_action(Add, %{value: 100, amount: 1}, name: :add)
result = Support.ok!(Exec.run(flow, %{value: 2}))
%{add: [%{value: 3}]} = Exec.results(result)

Support.print(
  "03 static params and runtime input",
  %{
    static_params: %{value: 100, amount: 1},
    runtime_input: %{value: 2},
    results: Exec.results(result)
  }
)
