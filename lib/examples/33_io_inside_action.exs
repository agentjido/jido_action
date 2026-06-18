Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.IOAction
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.from_action(IOAction, %{message: "hello from action"}, name: :io_action)
  |> Flow.policy(:io_action, %{timeout_ms: 1_000})

{result, output} = Support.capture_io(fn -> Support.ok!(Exec.run(flow, %{})) end)

%{io_action: [%{message: "hello from action"}]} = Exec.results(result)
"hello from action\n" = output

Support.print("33 IO inside action", %{captured: output, results: Exec.results(result)})
