Code.require_file("support.exs", __DIR__)

alias Jido.Action.Output
alias Jido.Exec
alias Jido.Examples.Actions.{BatchOutput, OpaqueDirective, RawPayload, StreamAction}
alias Jido.Examples.Support

Support.ensure!()

raw =
  Support.ok!(Exec.run(RawPayload, %{payload: {:external, %{id: "evt_123"}}}, name: :raw_payload))

batch = Support.ok!(Exec.run(BatchOutput, %{count: 3}, name: :batch_output))
stream = Support.ok!(Exec.run(StreamAction, %{limit: 3}, name: :stream_action))
opaque = Support.ok!(Exec.run(OpaqueDirective, %{}, name: :opaque_directive))

%{
  raw_payload: [
    %Output{kind: :raw, value: {:external, %{id: "evt_123"}}, meta: %{source: :external}}
  ]
} =
  Exec.results(raw)

%{batch_output: [%Output{kind: :batch, value: batch_values, meta: %{count: 3}}]} =
  Exec.results(batch)

%{stream_action: [%Output{kind: :stream, value: stream_value, meta: %{source: :range, limit: 3}}]} =
  Exec.results(stream)

%{
  opaque_directive: [
    %Output{kind: :opaque, value: {:external_handle, handle}, meta: %{owner: :external_system}}
  ]
} =
  Exec.results(opaque)

[%{directives: %{route: :inspect}, status: :ok}] = opaque.directives

3 = length(batch_values)
[2, 4, 6] = stream_values = Enum.to_list(stream_value)
true = is_integer(handle)

Support.print("51 action output envelopes", %{
  raw: Exec.results(raw),
  batch: batch_values,
  stream_values: stream_values,
  opaque: Exec.results(opaque),
  directives: opaque.directives
})
