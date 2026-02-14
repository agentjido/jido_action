defmodule JidoTest.Exec.TelemetrySanitizationTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Exec.Telemetry

  defmodule CredentialsStruct do
    defstruct [:api_key, :note, :nested]
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  setup do
    test_pid = self()
    handler_id = "jido-telemetry-sanitization-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:jido, :action, :start], [:jido, :action, :stop]],
        &__MODULE__.handle_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emit_start_event redacts sensitive keys and caps payload size" do
    long_string = String.duplicate("x", 300)

    params = %{
      password: "super-secret",
      list: Enum.to_list(1..30),
      nested: %{layer1: %{layer2: %{layer3: %{layer4: %{token: "inner-secret"}}}}},
      data: %CredentialsStruct{
        api_key: "api-123",
        note: long_string,
        nested: %{client_secret: "nested-secret"}
      }
    }

    context = %{"authorization" => "Bearer top-secret", "note" => long_string}

    assert :ok = Telemetry.emit_start_event(__MODULE__, params, context)

    assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, metadata}

    assert metadata.params.password == "[REDACTED]"
    assert metadata.context["authorization"] == "[REDACTED]"
    assert String.contains?(metadata.context["note"], "...(truncated 44 bytes)")
    assert length(metadata.params.list) == 26
    assert List.last(metadata.params.list) == %{__truncated_items__: 5}
    assert metadata.params.data.api_key == "[REDACTED]"
    assert metadata.params.data.nested.client_secret == "[REDACTED]"
    assert metadata.params.data.__struct__ == CredentialsStruct

    assert get_in(metadata, [:params, :nested, :layer1, :layer2]) == %{
             __truncated_depth__: 4,
             type: :map,
             size: 1
           }
  end

  test "emit_end_event sanitizes result payloads" do
    long_string = String.duplicate("z", 280)

    assert :ok =
             Telemetry.emit_end_event(
               __MODULE__,
               %{input: 1},
               %{secret: "hidden"},
               {:ok, %{token: "tok-123", payload: long_string}}
             )

    assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, metadata}

    assert metadata.context.secret == "[REDACTED]"
    assert {:ok, result_payload} = metadata.result
    assert result_payload.token == "[REDACTED]"
    assert String.contains?(result_payload.payload, "...(truncated 24 bytes)")
  end

  test "log helpers sanitize sensitive data and large payloads" do
    long_string = String.duplicate("a", 300)

    log =
      capture_log(fn ->
        Telemetry.log_execution_start(
          __MODULE__,
          %{api_key: "api-secret", payload: long_string},
          %{password: "pwd-123"}
        )

        Telemetry.log_execution_end(
          __MODULE__,
          %{},
          %{},
          {:ok, %{token: "t-123", payload: long_string}}
        )

        Telemetry.cond_log_start(
          :notice,
          __MODULE__,
          %{authorization: "Bearer 123"},
          %{client_secret: "very-secret"}
        )

        Telemetry.cond_log_end(
          :debug,
          __MODULE__,
          {:error, %{cookie: "session-cookie", note: long_string}}
        )
      end)

    assert log =~ "[REDACTED]"
    assert log =~ "...(truncated 44 bytes)"
    refute log =~ "api-secret"
    refute log =~ "pwd-123"
    refute log =~ "t-123"
    refute log =~ "Bearer 123"
    refute log =~ "session-cookie"
    refute log =~ "very-secret"
  end
end
