Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Examples.Actions.{DirectiveAction, ErrorDirectiveAction}
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

success = Support.ok!(Exec.run(DirectiveAction, %{value: 1}, name: :directive_action))
failure = Support.error!(Exec.run(ErrorDirectiveAction, %{}, name: :error_directive_action))

[%{directives: %{route: :next}, status: :ok}] = success.directives
[%{directives: %{route: :fallback}, status: :error}] = failure.directives

Support.print(
  "35 directives success and error",
  %{success: success.directives, failure: failure.directives}
)
