Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Examples.Actions.KillAction
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

result = Support.error!(Exec.run(KillAction, %{}, name: :kill_action))
:error = result.status
:killed = result.error.details.reason.details.reason

Support.print("32 untrappable exit", %{
  caller_alive?: Process.alive?(self()),
  reason: result.error.details.reason.details
})
