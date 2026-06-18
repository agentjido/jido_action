Code.require_file("support.exs", __DIR__)

alias Jido.Action.Error
alias Jido.Exec
alias Jido.Examples.Actions.UnexpectedReturn
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

result = Support.error!(Exec.run(UnexpectedReturn, %{}, name: :unexpected_return))
:error = result.status
%{type: :execution_error} = error = Error.to_map(result.error)

Support.print("30 unexpected return shape", %{status: result.status, error: error})
