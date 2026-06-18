Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Examples.Actions.{RaiseAction, ThrowAction}
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

raised = Support.error!(Exec.run(RaiseAction, %{}, name: :raise_action))
thrown = Support.error!(Exec.run(ThrowAction, %{}, name: :throw_action))

:error = raised.status
:error = thrown.status

Support.print(
  "31 raise and throw",
  %{
    raised_reason: raised.error.details.reason.message,
    thrown_reason: thrown.error.details.reason.message
  }
)
