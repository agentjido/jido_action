Code.require_file("support.exs", __DIR__)

alias Jido.Action.Error
alias Jido.Exec
alias Jido.Examples.Actions.InvalidOutput
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

result = Support.error!(Exec.run(InvalidOutput, %{}, name: :invalid_output))
:error = result.status
%{type: :execution_error} = error = Error.to_map(result.error)

Support.print("29 invalid output schema", %{status: result.status, error: error})
