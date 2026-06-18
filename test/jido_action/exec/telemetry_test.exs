defmodule JidoTest.ExecTelemetryTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias JidoTest.TestActions.{Add, ErrorAction, Slow, WithDirective}

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  describe "action telemetry boundary" do
    setup do
      handler_id = "jido-action-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [[:jido, :action, :start], [:jido, :action, :stop]],
          &__MODULE__.handle_telemetry_event/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits low-cardinality action spans for Jido action runnables" do
      flow =
        Flow.new(:telemetry_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3}, jido: :tenant_a)
      assert Exec.results(result).again == [%{value: 6}]

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, start_metadata}

      assert Map.drop(start_metadata, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a
             }

      refute Map.has_key?(start_metadata, :params)
      refute Map.has_key?(start_metadata, :context)

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a,
               outcome: :ok
             }

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, second_start}

      assert Map.drop(second_start, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a
             }

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, second_stop}

      assert Map.drop(second_stop, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a,
               outcome: :ok
             }
    end

    test "emits error metadata for failed action runnables" do
      flow = Flow.from_action(ErrorAction, %{type: :error}, name: :failing_action)

      assert {:error, %Result{status: :error}} =
               silence_logger(fn -> Exec.run(flow, %{}) end)

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, start_metadata}

      assert Map.drop(start_metadata, [:telemetry_span_context]) == %{action: ErrorAction}

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: ErrorAction,
               outcome: :error,
               error_type: :execution_error,
               retryable?: true
             }
    end

    test "emits timeout metadata from the Runic policy boundary" do
      flow =
        Flow.from_action(Slow, %{delay: 50}, name: :slow)
        |> Flow.policy(:slow, %{timeout_ms: 10, max_retries: 0, backoff: :none})

      assert {:error, %Result{status: :error}} =
               silence_logger(fn -> Exec.run(flow, %{}) end)

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, start_metadata}

      assert Map.drop(start_metadata, [:telemetry_span_context]) == %{action: Slow}

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: Slow,
               outcome: :error,
               error_type: :timeout,
               retryable?: true
             }
    end

    test "emits directive and deadline metadata from worker results" do
      directive_flow = Flow.from_action(WithDirective, %{value: 1}, name: :with_directive)

      assert {:ok, %Result{}} = Exec.run(directive_flow, %{})

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, _metadata}
      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: WithDirective,
               outcome: :ok,
               directive?: true
             }

      deadline_flow = Flow.from_action(Add, %{amount: 1}, name: :add)

      assert {:error, %Result{status: :error}} =
               silence_logger(fn ->
                 Exec.run(deadline_flow, %{value: 1},
                   deadline_at: System.monotonic_time(:millisecond) - 1
                 )
               end)

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, _metadata}
      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, deadline_metadata}

      assert Map.drop(deadline_metadata, [:telemetry_span_context]) == %{
               action: Add,
               outcome: :error,
               error_type: :timeout,
               retryable?: true
             }
    end
  end
end
