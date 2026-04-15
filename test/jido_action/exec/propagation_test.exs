defmodule JidoTest.Exec.PropagationTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Exec.Chain
  alias Jido.Exec.Propagation

  @prop_key :jido_test_runtime_context

  defmodule ProcessDictionaryPropagator do
    @behaviour Jido.Exec.ContextPropagator

    @prop_key :jido_test_runtime_context

    @impl true
    def capture, do: Process.get(@prop_key)

    @impl true
    def attach(value) do
      previous = Process.get(@prop_key)

      case value do
        nil -> Process.delete(@prop_key)
        _value -> Process.put(@prop_key, value)
      end

      previous
    end

    @impl true
    def detach(previous) do
      case previous do
        nil -> Process.delete(@prop_key)
        _value -> Process.put(@prop_key, previous)
      end

      :ok
    end
  end

  defmodule ExplodingCapturePropagator do
    @behaviour Jido.Exec.ContextPropagator

    @impl true
    def capture, do: raise("capture exploded")

    @impl true
    def attach(value), do: value

    @impl true
    def detach(_value), do: :ok
  end

  defmodule ReportingAction do
    use Jido.Action,
      name: "propagation_reporting_action",
      description: "Reports the currently attached runtime context"

    @prop_key :jido_test_runtime_context

    @impl true
    def run(%{label: label, test_pid: test_pid}, _context) do
      value = Process.get(@prop_key)
      send(test_pid, {:propagated_context, label, value, self()})
      {:ok, %{label: label, propagated: value}}
    end
  end

  defmodule CompensationReportingAction do
    use Jido.Action,
      name: "propagation_compensation_action",
      description: "Reports propagated runtime context during compensation",
      compensation: [enabled: true, timeout: 100]

    @prop_key :jido_test_runtime_context

    @impl true
    def run(_params, _context) do
      {:error, Error.execution_error("compensation trigger")}
    end

    @impl true
    def on_error(%{test_pid: test_pid}, _error, _context, _opts) do
      value = Process.get(@prop_key)
      send(test_pid, {:compensation_context, value, self()})
      {:ok, %{compensation_context: %{propagated: value}}}
    end
  end

  setup do
    original_observability = Application.get_env(:jido_action, :observability)

    on_exit(fn ->
      restore_observability_env(original_observability)
      Process.delete(@prop_key)
    end)

    Process.delete(@prop_key)
    :ok
  end

  describe "Propagation.with_attached/2" do
    test "restores the previous process-local value after the callback returns" do
      Process.put(@prop_key, "parent-trace")

      snapshot =
        Propagation.capture(context_propagators: [ProcessDictionaryPropagator])

      Process.put(@prop_key, "worker-existing")

      assert :ok =
               Propagation.with_attached(snapshot, fn ->
                 assert Process.get(@prop_key) == "parent-trace"
                 :ok
               end)

      assert Process.get(@prop_key) == "worker-existing"
    end
  end

  describe "supervised execution boundaries" do
    test "propagates runtime context into timeout-supervised action execution" do
      Process.put(@prop_key, "timeout-trace")

      assert {:ok, %{propagated: "timeout-trace"}} =
               Exec.run(
                 ReportingAction,
                 %{label: :timeout, test_pid: self()},
                 %{},
                 timeout: 100,
                 context_propagators: [ProcessDictionaryPropagator]
               )

      assert_receive {:propagated_context, :timeout, "timeout-trace", action_pid}
      refute action_pid == self()
    end

    test "propagates runtime context across async wrapper and nested timeout execution" do
      Process.put(@prop_key, "async-trace")

      async_ref =
        Exec.run_async(
          ReportingAction,
          %{label: :async, test_pid: self()},
          %{},
          timeout: 100,
          context_propagators: [ProcessDictionaryPropagator]
        )

      assert_receive {:propagated_context, :async, "async-trace", action_pid}
      refute action_pid == self()
      refute action_pid == async_ref.pid
      assert {:ok, %{propagated: "async-trace"}} = Exec.await(async_ref, 1_000)
    end

    test "propagates runtime context into compensation callbacks" do
      Process.put(@prop_key, "comp-trace")

      assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} =
               Exec.run(
                 CompensationReportingAction,
                 %{test_pid: self()},
                 %{},
                 timeout: 100,
                 context_propagators: [ProcessDictionaryPropagator]
               )

      assert_receive {:compensation_context, "comp-trace", compensation_pid}
      refute compensation_pid == self()
      assert error.details.compensation_context == %{propagated: "comp-trace"}
    end

    test "propagates runtime context into async chain execution" do
      Process.put(@prop_key, "chain-trace")

      task =
        Chain.chain(
          [ReportingAction],
          %{label: :chain, test_pid: self()},
          async: true,
          timeout: 100,
          context_propagators: [ProcessDictionaryPropagator]
        )

      assert %Task{} = task
      assert_receive {:propagated_context, :chain, "chain-trace", action_pid}
      refute action_pid == self()
      refute action_pid == task.pid
      assert {:ok, %{propagated: "chain-trace"}} = Task.await(task, 1_000)
    end
  end

  describe "configuration resolution" do
    test "uses application observability config when execution opts omit propagators" do
      Application.put_env(:jido_action, :observability,
        context_propagators: [ProcessDictionaryPropagator],
        context_propagator_failure_mode: :warn
      )

      Process.put(@prop_key, "config-trace")

      assert {:ok, %{propagated: "config-trace"}} =
               Exec.run(ReportingAction, %{label: :config, test_pid: self()}, %{}, timeout: 100)

      assert_receive {:propagated_context, :config, "config-trace", _action_pid}
    end
  end

  describe "propagator failure modes" do
    test "warn mode logs and skips failing propagators while preserving healthy ones" do
      Process.put(@prop_key, "warn-trace")

      log =
        capture_log(fn ->
          snapshot =
            Propagation.capture(
              context_propagators: [ExplodingCapturePropagator, ProcessDictionaryPropagator],
              context_propagator_failure_mode: :warn
            )

          assert :ok =
                   Propagation.with_attached(snapshot, fn ->
                     assert Process.get(@prop_key) == "warn-trace"
                     :ok
                   end)
        end)

      assert log =~ "context propagator capture/0 failed"
      assert log =~ "ExplodingCapturePropagator"
    end

    test "strict mode raises when a propagator callback fails" do
      assert_raise RuntimeError, ~r/context propagator capture\/0 failed/, fn ->
        Propagation.capture(
          context_propagators: [ExplodingCapturePropagator],
          context_propagator_failure_mode: :strict
        )
      end
    end
  end

  defp restore_observability_env(nil), do: Application.delete_env(:jido_action, :observability)

  defp restore_observability_env(config),
    do: Application.put_env(:jido_action, :observability, config)
end
