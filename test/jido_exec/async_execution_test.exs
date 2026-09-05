defmodule JidoActionTest.Exec.AsyncExecutionTest do
  use JidoActionTest.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Exec
  alias Jido.Exec.Error
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.{MathFlow, BlockingFlow}
  alias JidoActionTest.Fixtures.Actions.{Add, ErrorAction, ExtrasAction}
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  defmodule IOAction do
    use Jido.Action, name: "async_io_action"

    @impl Jido.Action
    def run(%{message: message}, _context) do
      IO.puts(message)
      {:ok, %{message: message}}
    end
  end

  test "returns an owner-bound handle and preserves Action results" do
    handle = Exec.run_async(Add, %{value: 2})

    assert %{
             ref: ref,
             pid: pid,
             owner: owner,
             monitor_ref: monitor_ref,
             state: state
           } = handle

    assert is_reference(ref)
    assert is_pid(pid)
    assert owner == self()
    assert is_reference(monitor_ref)
    assert {:jido_exec_async_state, state_ref} = state
    assert is_reference(state_ref)
    assert {:ok, %{value: 3}} = Exec.await(handle, 1_000)

    extras_handle = Exec.run_async(ExtrasAction, %{value: 4}, %{trace_id: "trace-4"})

    assert {:ok, %{value: 4}, %{trace_id: "trace-4"}} =
             Exec.await(extras_handle, 1_000)
  end

  test "supports the default and infinite await limits" do
    default_handle = Exec.run_async(Add, %{value: 2})
    assert {:ok, %{value: 3}} = Exec.await(default_handle)

    infinite_handle = Exec.run_async(Add, %{value: 4})
    assert {:ok, %{value: 5}} = Exec.await(infinite_handle, :infinity)
  end

  test "routes asynchronous Action IO through the owner group leader" do
    output =
      capture_io(fn ->
        handle = Exec.run_async(IOAction, %{message: "async action output"})

        assert {:ok, %{message: "async action output"}} =
                 Exec.await(handle, 1_000)
      end)

    assert output == "async action output\n"
  end

  test "routes concurrent asynchronous Flow IO through the owner group leader" do
    flow = io_parallel_flow()

    output =
      capture_io(fn ->
        handle = Exec.run_async(flow, %{}, %{}, max_concurrency: 2)

        assert {:ok,
                %{
                  left: %{message: "async flow left"},
                  right: %{message: "async flow right"}
                }} = Exec.await(handle, 1_000)
      end)

    assert output |> String.split("\n", trim: true) |> Enum.sort() ==
             ["async flow left", "async flow right"]
  end

  test "preserves Action validation and execution errors" do
    invalid = Exec.run_async(Add, %{value: "bad"})
    assert {:error, %Jido.Action.Error.InvalidInputError{}} = Exec.await(invalid, 1_000)

    failed = Exec.run_async(ErrorAction, %{error_type: :validation})
    assert {:error, %Jido.Action.Error.ExecutionFailureError{}} = Exec.await(failed, 1_000)
  end

  test "runs Flow modules, values, and Instructions to completion" do
    instruction = Instruction.new!(target: MathFlow, params: %{value: 3})

    for target <- [MathFlow, MathFlow.flow(), instruction] do
      handle = Exec.run_async(target, %{value: 3})
      assert {:ok, %{value: 8}} = Exec.await(handle, 1_000)
    end
  end

  test "does not treat a paused step-wise execution as a run target" do
    assert {:ok, execution} = Exec.start(MathFlow, %{value: 3})
    handle = Exec.run_async(execution)

    assert {:error, %Jido.Action.Error.ConfigurationError{}} = Exec.await(handle, 1_000)
  end

  test "keeps the complete-call timeout separate from the await timeout" do
    handle =
      Exec.run_async(
        BlockingFlow,
        %{value: 1},
        %{test_pid: self()},
        timeout: 50
      )

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    assert {:error, %Jido.Flow.Error.TimeoutError{timeout: 50}} = Exec.await(handle, 1_000)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "an await timeout cancels active Action work" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    assert {:error, %Error.AsyncTimeoutError{timeout: 0, details: %{operation: :await}}} =
             Exec.await(handle, 0)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "cancel stops every active worker in a concurrent Flow wave" do
    flow = blocking_parallel_flow()
    handle = Exec.run_async(flow, %{}, %{test_pid: self()}, max_concurrency: 2)

    workers =
      for _index <- 1..2 do
        assert_receive {:blocking_flow_node_started, worker}, 1_000
        worker
      end

    monitors = Enum.map(workers, &{&1, Process.monitor(&1)})
    assert :ok = Exec.cancel(handle)

    for {worker, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    end
  end

  test "only the owner can await or cancel a handle" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    test_pid = self()

    non_owner =
      spawn(fn ->
        send(test_pid, {:non_owner_await, Exec.await(handle, 10)})
        send(test_pid, {:non_owner_cancel, Exec.cancel(handle)})
      end)

    assert_receive {:non_owner_await, {:error, %Error.InvalidHandleError{}}}, 1_000
    assert_receive {:non_owner_cancel, {:error, %Error.InvalidHandleError{}}}, 1_000
    refute non_owner == handle.owner
    assert Process.alive?(worker)
    assert :ok = Exec.cancel(handle)
  end

  test "owner death cancels the async execution and its Action worker" do
    test_pid = self()

    owner =
      spawn(fn ->
        handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: test_pid})
        send(test_pid, {:owner_handle, handle})

        receive do
          :stop_owner -> :ok
        end
      end)

    assert_receive {:owner_handle, handle}, 1_000
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    handle_monitor = Process.monitor(handle.pid)
    worker_monitor = Process.monitor(worker)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^handle_monitor, :process, handle_pid, :normal}, 1_000
    assert handle_pid == handle.pid
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "routes the handle and target work through a named supervisor" do
    instance = unique_module("AsyncJido")
    task_supervisor = Module.concat(instance, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: task_supervisor})

    handle =
      Exec.run_async(
        BlockingAction,
        %{value: 1},
        %{test_pid: self()},
        task_supervisor: task_supervisor
      )

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    children = Task.Supervisor.children(task_supervisor)
    assert handle.pid in children
    assert worker in children
    assert :ok = Exec.cancel(handle)
  end

  test "validates handles and timeouts" do
    assert {:error, %Error.InvalidHandleError{}} = Exec.await(%{}, 10)
    assert {:error, %Error.InvalidHandleError{}} = Exec.cancel(:invalid)

    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    assert {:error, %Error.InvalidHandleError{}} = Exec.await(handle, :soon)
    worker_monitor = Process.monitor(worker)
    assert :ok = Exec.cancel(handle)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
  end

  test "rejects a live PID without stopping the execution" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})

    try do
      assert_receive {:blocking_flow_node_started, worker}, 1_000
      assert {:error, %Error.InvalidHandleError{} = error} = Exec.cancel(handle.pid)
      assert error.message == "Invalid asynchronous execution handle"
      assert error.details == %{operation: :cancel, value: handle.pid}

      send(worker, :finish)
      assert {:ok, %{value: 1}} = Exec.await(handle, 1_000)
    after
      Exec.cancel(handle)
    end
  end

  test "rejects a dead PID without consuming its handle" do
    %{pid: pid, monitor_ref: monitor_ref} = handle = Exec.run_async(Add, %{value: 1})

    try do
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000
      assert {:error, %Error.InvalidHandleError{} = error} = Exec.cancel(pid)
      assert error.message == "Invalid asynchronous execution handle"
      assert error.details == %{operation: :cancel, value: pid}
      assert {:ok, %{value: 2}} = Exec.await(handle, 1_000)
    after
      Exec.cancel(handle)
    end
  end

  test "reports a handle whose process is no longer running" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, monitor_ref, :process, pid, :killed}, 1_000
    assert monitor_ref == handle.monitor_ref
    assert pid == handle.pid
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

    assert {:error, %Error.AsyncExecutionError{details: %{reason: :noproc}}} =
             Exec.await(handle, 10)
  end

  test "reports routing and option failures before an async process starts" do
    missing_supervisor = unique_module("MissingAsyncSupervisor")

    assert_raise Jido.Action.Error.InvalidInputError, fn ->
      Exec.run_async(Add, %{value: 1}, %{}, task_supervisor: missing_supervisor)
    end

    assert_raise Error.AsyncExecutionError, fn ->
      Exec.run_async(Add, %{value: 1}, %{}, :invalid)
    end
  end

  defp blocking_parallel_flow do
    Flow.new!(
      name: "async_parallel_flow",
      components: [
        Step.new!(name: "left", action: BlockingAction, params: %{value: :left}),
        Step.new!(name: "right", action: BlockingAction, params: %{value: :right})
      ],
      output: %{left: Ref.result("left"), right: Ref.result("right")}
    )
  end

  defp io_parallel_flow do
    Flow.new!(
      name: "async_io_flow",
      components: [
        Step.new!(name: "left", action: IOAction, params: %{message: "async flow left"}),
        Step.new!(name: "right", action: IOAction, params: %{message: "async flow right"})
      ],
      output: %{left: Ref.result("left"), right: Ref.result("right")}
    )
  end
end
