Code.require_file("support.exs", __DIR__)

alias Jido.Action.Error
alias Jido.Exec
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

result = Support.error!(Exec.run(Add, %{value: "bad", amount: 1}, name: :add))
:error = result.status
%{type: :execution_error} = error = Error.to_map(result.error)

Support.print("28 invalid input schema", %{status: result.status, error: error})
