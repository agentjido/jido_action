defmodule JidoActionTest.Exec.NativeRuntimePolicyTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  defmodule LoggerMetadataAction do
    use Jido.Action, name: "native_logger_metadata_action"

    @impl Jido.Action
    def run(params, %{test_pid: test_pid}) do
      send(test_pid, {:action_logger_metadata, params.id, Logger.metadata()})
      {:ok, params}
    end
  end

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Action.Error.TimeoutError, as: ActionTimeoutError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Error.ExecutionFailureError, as: FlowExecutionFailureError
  alias Jido.Flow.Error.InvalidExecutionError
  alias Jido.Flow.Error.TimeoutError, as: FlowTimeoutError
  alias Jido.Flow.{Ref, Step}
  alias Jido.Instruction

  alias JidoActionTest.Fixtures.{
    AsyncMathFlow,
    BlockingFlow,
    ConcurrencyProbeAction,
    ControlledErrorAction
  }

  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures
  alias JidoActionTest.Fixtures.FlowAuthoring, as: FlowFixtures
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction, RecorderAction}
  alias Runic.Workflow.Runnable

  test "preserves caller Logger metadata in an asynchronous runnable" do
    flow =
      Flow.new!(
        name: "async_logger_metadata",
        components: [
          Step.new!(name: "metadata", action: LoggerMetadataAction, params: %{id: :metadata})
        ],
        output: Ref.result("metadata")
      )

    metadata_key = :jido_test_request_id
    Logger.metadata([{metadata_key, "request-123"}])

    assert Exec.run(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 1) ==
             {:ok, %{id: :metadata}}

    assert_receive {:action_logger_metadata, :metadata, metadata}
    assert metadata[metadata_key] == "request-123"
  end

  @tag timeout: 5_000
  test "runs independent native branches concurrently" do
    probe = start_supervised!({Agent, fn -> %{max: 0, running: 0} end})
    flow = ExecFixtures.probe_diamond_flow()
    test_pid = self()

    task =
      Task.async(fn ->
        Exec.run(flow, %{}, %{probe: probe, test_pid: test_pid},
          async: true,
          max_concurrency: 2
        )
      end)

    starts = Enum.map(1..2, fn _index -> receive_probe_start(probe) end)
    assert Agent.get(probe, & &1.max) == 2
    Enum.each(starts, fn {_side, worker} -> send(worker, {:release, probe}) end)
    assert Enum.map(starts, &elem(&1, 0)) |> Enum.sort() == [:left, :right]
    assert Task.await(task) == {:ok, %{left: :left, right: :right}}
  end

  test "supports Flow module options and validates policy values" do
    assert Exec.run(AsyncMathFlow, %{value: 3}, %{}, async: true) == {:ok, %{value: 4}}
    flow = FlowFixtures.math_flow!()
    assert Exec.run(flow, %{value: 3}) == Exec.run(flow, %{value: 3}, %{}, [])

    assert Exec.run(flow, %{value: 3}, %{}, timeout: 100) == {:ok, %{value: 8}}

    assert {:error, %InvalidExecutionError{details: %{option: :timeout, value: :soon}}} =
             Exec.run(flow, %{value: 3}, %{}, timeout: :soon)

    assert {:error, %InvalidExecutionError{details: %{option: :timeout}}} =
             Exec.start(flow, %{value: 3}, %{}, timeout: 100)

    assert {:error, %InvalidExecutionError{details: %{option: :async}}} =
             Exec.run(flow, %{value: 3}, %{}, async: :yes)

    assert {:error, %InvalidExecutionError{details: %{option: :max_concurrency}}} =
             Exec.run(flow, %{value: 3}, %{}, max_concurrency: 0)

    assert {:error, %InvalidExecutionError{message: "run options must be a keyword list"}} =
             Exec.run(flow, %{}, %{}, :not_options)

    assert {:error, %InvalidExecutionError{message: "run options must be a keyword list"}} =
             Exec.run(flow, %{}, %{}, [{:timeout, 10}, :not_an_option])
  end

  test "rejects Flow run options for Actions and Action Instructions" do
    assert {:error, %InvalidInputError{details: %{executable_type: :action}}} =
             Exec.run(Add, %{value: 1}, %{}, async: true)

    instruction = Instruction.new!(target: Add, params: %{value: 1})

    assert {:error, %InvalidInputError{details: %{executable_type: :instruction}}} =
             Exec.run(instruction, %{}, %{}, async: true)
  end

  test "enforces one complete-call timeout for every executable form" do
    owner = self()
    timeout = 500

    for {form, {target, input, context}} <-
          ExecFixtures.blocking_execution_forms(BlockingFlow, owner) do
      task = Task.async(fn -> Exec.run(target, input, context, timeout: timeout) end)
      assert_receive {:blocking_flow_node_started, worker}, 1_000

      case Task.await(task, timeout + 1_000) do
        {:error, %ActionTimeoutError{timeout: ^timeout, details: %{retry: false}} = error}
        when form in [:action, :action_instruction] ->
          refute Jido.Action.Error.retryable?(error)

        {:error, %FlowTimeoutError{timeout: ^timeout, details: %{retry: false}} = error}
        when form in [:flow_value, :flow_module, :flow_instruction, :subflow] ->
          refute Jido.Flow.Error.retryable?(error)
          assert %{type: :flow_timeout, retryable?: false} = Jido.Flow.Error.to_map(error)
      end

      assert_process_stops(worker)
    end
  end

  test "a zero timeout dispatches no work for every executable form" do
    for {form, {target, input, context}} <-
          ExecFixtures.blocking_execution_forms(BlockingFlow, self()) do
      case Exec.run(target, input, context, timeout: 0) do
        {:error, %ActionTimeoutError{timeout: 0}} when form in [:action, :action_instruction] ->
          :ok

        {:error, %FlowTimeoutError{timeout: 0}}
        when form in [:flow_value, :flow_module, :flow_instruction, :subflow] ->
          :ok
      end

      refute_received {:blocking_flow_node_started, _worker}
    end
  end

  test "a Flow timeout stops concurrent workers and releases its limiter" do
    flow =
      Flow.new!(
        name: "concurrent_flow_timeout",
        components: [
          Step.new!(
            name: "left",
            action: ExecFixtures.BlockingAction,
            params: %{value: :left}
          ),
          Step.new!(
            name: "right",
            action: ExecFixtures.BlockingAction,
            params: %{value: :right}
          )
        ],
        output: %{left: Ref.result("left"), right: Ref.result("right")}
      )

    assert {:error, %FlowTimeoutError{}} =
             Exec.run(flow, %{}, %{test_pid: self()},
               async: true,
               max_concurrency: 2,
               timeout: 1_000
             )

    workers =
      for _index <- 1..2 do
        assert_receive {:blocking_flow_node_started, worker}, 1_000
        worker
      end

    assert length(Enum.uniq(workers)) == 2
    Enum.each(workers, &assert_process_stops/1)
  end

  test "validates the Jido instance routing option for Actions and Flows" do
    flow = FlowFixtures.math_flow!()

    assert {:error, %InvalidInputError{details: %{option: :jido, value: "bad"}}} =
             Exec.run(Add, %{value: 1}, %{}, jido: "bad")

    assert {:error, %InvalidExecutionError{details: %{option: :jido, value: "bad"}}} =
             Exec.run(flow, %{value: 1}, %{}, jido: "bad")

    missing_instance = Module.concat(__MODULE__, MissingJidoInstance)
    missing_supervisor = Module.concat(missing_instance, TaskSupervisor)

    for {form, {target, input, context}} <-
          ExecFixtures.blocking_execution_forms(BlockingFlow, self()) do
      case Exec.run(target, input, context, jido: missing_instance) do
        {:error,
         %InvalidInputError{
           message: "Task Supervisor is not running",
           details: %{jido: ^missing_instance, task_supervisor: ^missing_supervisor}
         }}
        when form in [:action, :action_instruction] ->
          :ok

        {:error,
         %InvalidExecutionError{
           message: "Task Supervisor is not running",
           details: %{jido: ^missing_instance, task_supervisor: ^missing_supervisor}
         }}
        when form in [:flow_value, :flow_module, :flow_instruction, :subflow] ->
          :ok
      end

      refute_received {:blocking_flow_node_started, _worker}
    end
  end

  defp assert_process_stops(pid) do
    monitor = Process.monitor(pid)

    if Process.alive?(pid) do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    else
      assert_receive {:DOWN, ^monitor, :process, ^pid, :noproc}, 1_000
    end
  end

  test "scopes the concurrency limiter to one execution operation" do
    flow =
      Flow.new!(
        name: "limiter_lifecycle",
        components: [
          Step.new!(
            name: "blocking",
            action: ExecFixtures.BlockingAction,
            params: %{test_pid: Ref.context(:test_pid)}
          )
        ],
        output: Ref.result("blocking")
      )

    assert {:ok, execution} =
             Exec.start(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 2)

    assert Jido.Exec.ConcurrencyLimiter.whereis(execution.id) == nil
    [runnable] = Exec.ready(execution)
    task = Task.async(fn -> Exec.step(execution, runnable) end)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    limiter = Jido.Exec.ConcurrencyLimiter.whereis(execution.id)
    assert Process.alive?(limiter)
    send(worker, :finish)

    assert {:ok, %Runnable{status: :completed}, execution} = Task.await(task)
    assert Exec.status(execution) == :succeeded
    assert Jido.Exec.ConcurrencyLimiter.whereis(execution.id) == nil
  end

  test "aggregates failures from one asynchronous wave" do
    flow =
      Flow.new!(
        name: "native_multiple_failures",
        components: [
          Step.new!(
            name: "first",
            action: ControlledErrorAction,
            params: %{message: "first failure"}
          ),
          Step.new!(
            name: "second",
            action: ControlledErrorAction,
            params: %{message: "second failure"}
          )
        ],
        output: %{first: Ref.result("first"), second: Ref.result("second")}
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{}, async: true, max_concurrency: 2)
    assert {:ok, runnables, execution} = Exec.wave(execution)
    assert Enum.all?(runnables, &(&1.status == :failed))
    assert Exec.status(execution) == :failed

    assert {:error, %FlowExecutionFailureError{failures: failures}} = Exec.result(execution)
    assert Enum.map(failures, & &1.node) |> Enum.sort() == ["first", "second"]
    assert Enum.all?(failures, &is_integer(&1.runnable_id))
  end

  test "a selected failure does not dispatch another ready runnable" do
    flow =
      Flow.new!(
        name: "selected_failure",
        components: [
          Step.new!(
            name: "fail",
            action: ControlledErrorAction,
            params: %{message: "failed first"}
          ),
          Step.new!(name: "independent", action: RecorderAction, params: %{side: :independent})
        ],
        output: Ref.result("independent")
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    runnable = Enum.find(Exec.ready(execution), &(&1.node.name == "fail"))
    assert {:ok, %Runnable{status: :failed}, execution} = Exec.step(execution, runnable)
    assert Exec.status(execution) == :failed
    refute_received {RecorderAction, %{side: :independent}}
  end

  test "a wave executes its complete frozen ready set before failure" do
    flow =
      Flow.new!(
        name: "frozen_wave_failure",
        components: [
          Step.new!(
            name: "fail",
            action: ControlledErrorAction,
            params: %{message: "failed"}
          ),
          Step.new!(name: "record", action: RecorderAction, params: %{side: :record})
        ],
        output: Ref.result("record")
      )

    assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
    assert {:ok, runnables, execution} = Exec.wave(execution)
    assert Enum.count(runnables, &(&1.status == :failed)) == 1
    assert Enum.count(runnables, &(&1.status == :completed)) == 1
    assert_receive {RecorderAction, %{side: :record}}
    assert Exec.status(execution) == :failed
  end

  test "validates step selection and terminal operations" do
    flow =
      Flow.new!(
        name: "selection_validation",
        components: [Step.new!(name: "echo", action: EchoParamsAction)],
        output: Ref.result("echo")
      )

    assert {:ok, execution} = Exec.start(flow)

    assert {:error, %InvalidExecutionError{message: "flow execution is not complete"}} =
             Exec.result(execution)

    assert {:error, %InvalidExecutionError{message: "flow runnable is not ready"}} =
             Exec.step(execution, -1)

    assert {:error,
            %InvalidExecutionError{
              message: "flow runnable must be a ready Runnable or runnable ID"
            }} =
             Exec.step(execution, :bad)

    assert {:ok, %Runnable{}, execution} = Exec.step(execution)
    assert Exec.status(execution) == :succeeded

    assert {:error, %InvalidExecutionError{message: "flow execution is not running"}} =
             Exec.step(execution)

    assert {:error, %InvalidExecutionError{message: "flow execution is not running"}} =
             Exec.wave(execution)

    assert {:ok, ^execution} = Exec.continue(execution)
  end

  defp receive_probe_start(probe) do
    assert_receive {ConcurrencyProbeAction, :started, ^probe, side, worker}, 1_000
    {side, worker}
  end
end
