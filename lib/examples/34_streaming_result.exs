Code.require_file("support.exs", __DIR__)

alias Jido.Action.Output
alias Jido.Exec
alias Jido.Examples.Actions.StreamAction
alias Jido.Examples.Support

Support.ensure!()

result = Support.ok!(Exec.run(StreamAction, %{limit: 4}, name: :stream_action))

%{stream_action: [%Output{kind: :stream, value: stream, meta: %{source: :range, limit: 4}}]} =
  Exec.results(result)

%Stream{} = stream
stream_values = Enum.to_list(stream)
[2, 4, 6, 8] = stream_values

Support.print("34 streaming result", %{output: Exec.results(result), stream_values: stream_values})
