Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

result = Support.ok!(Exec.run(Add, %{value: 4, amount: 3}, name: :add))
%{add: [%{value: 7}]} = Exec.results(result)

Support.print("01 action contract", %{status: result.status, results: Exec.results(result)})
