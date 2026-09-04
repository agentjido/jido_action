defmodule JidoActionTest.Exec.NativeRuntimePolicyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag capture_log: true

  defmodule GatedErrorAction do
    use Jido.Action, name: "gated_error_action"

    @impl true
    def run(%{message: message}, %{owner: owner, ref: ref}) do
      send(owner, {ref, :ready, self()})

      receive do
        {^ref, :fail} -> {:error, Jido.Action.Error.execution_error(message)}
      end
    end
  end

  defmodule LoggerMetadataAction do
    use Jido.Action, name: "native_logger_metadata_action"

    @impl Jido.Action
    def run(params, %{test_pid: test_pid}) do
      send(test_pid, {:action_logger_metadata, params.id, Logger.metadata()})
      {:ok, params}
    end
  end

  defmodule BlockingDescriptorAction do
    def __jido_executable__ do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:descriptor_started, self()})

      receive do
        :release_descriptor -> Jido.Executable.action(__MODULE__)
      end
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  defmodule ContinueToBlockingFlowDescriptor do
    use Jido.Action, name: "continue_to_blocking_flow_descriptor"

    @impl true
    def run(params, _context) do
      {:continue, params, JidoActionTest.Exec.NativeRuntimePolicyTest.BlockingFlowDescriptor}
    end
  end

  defmodule BlockingFlowDescriptor do
    def __jido_executable__ do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:continuation_flow_descriptor_started, self()})

      receive do
        :release_descriptor -> Jido.Executable.flow(__MODULE__)
      end
    end

    def flow do
      Jido.Flow.new!(
        name: "blocking_descriptor_flow",
        components: [
          Jido.Flow.Step.new!(
            name: "add",
            action: JidoActionTest.Fixtures.Actions.Add,
            params: %{value: Jido.Flow.Ref.input(:value)}
          )
        ],
        output: Jido.Flow.Ref.result("add")
      )
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule ContinueToBlockingActionDescriptor do
    use Jido.Action, name: "continue_to_blocking_action_descriptor"

    @impl true
    def run(params, _context) do
      {:continue, params,
       JidoActionTest.Exec.NativeRuntimePolicyTest.BlockingActionDescriptorWithFlowHelper}
    end
  end

  defmodule BlockingActionDescriptorWithFlowHelper do
    def __jido_executable__ do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:continuation_action_descriptor_started, self()})

      receive do
        :release_descriptor -> Jido.Executable.action(__MODULE__)
      end
    end

    def flow, do: :unrelated_application_helper
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Action.Error.TimeoutError, as: ActionTimeoutError
  alias Jido.Exec
  alias Jido.Exec.Options
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

  alias JidoActionTest.Fixtures.InlineControlledFlow

  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures
  alias JidoActionTest.Fixtures.FlowAuthoring, as: FlowFixtures
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction, RecorderAction}
  alias Runic.Workflow.Runnable

  test "preserves caller Logger metadata in a concurrent runnable" do
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

    assert Exec.run(flow, %{}, %{test_pid: self()}, max_concurrency: 1) ==
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
        Exec.run(flow, %{}, %{probe: probe, test_pid: test_pid}, max_concurrency: 2)
      end)

    starts = Enum.map(1..2, fn _index -> receive_probe_start(probe) end)
    assert Agent.get(probe, & &1.max) == 2
    Enum.each(starts, fn {_side, worker} -> send(worker, {:release, probe}) end)
    assert Enum.map(starts, &elem(&1, 0)) |> Enum.sort() == [:left, :right]
    assert Task.await(task) == {:ok, %{left: :left, right: :right}}
  end

  test "bounds one native ready wave with max_concurrency" do
    probe = start_supervised!({Agent, fn -> %{max: 0, running: 0} end})
    flow = ExecFixtures.probe_diamond_flow()
    test_pid = self()

    task =
      Task.async(fn ->
        Exec.run(flow, %{}, %{probe: probe, test_pid: test_pid}, max_concurrency: 1)
      end)

    first = receive_probe_start(probe)
    refute_receive {ConcurrencyProbeAction, :started, ^probe, _side, _worker}, 100
    send(elem(first, 1), {:release, probe})

    second = receive_probe_start(probe)
    send(elem(second, 1), {:release, probe})

    assert Enum.map([first, second], &elem(&1, 0)) |> Enum.sort() == [:left, :right]
    assert Task.await(task) == {:ok, %{left: :left, right: :right}}
    assert Agent.get(probe, & &1.max) == 1
  end

  test "independent inline Steps obey the concurrency limit and return canonical results" do
    for limit <- [1, 2] do
      probe =
        start_supervised!(
          Supervisor.child_spec({Agent, fn -> %{max: 0, running: 0} end},
            id: {:inline_probe, limit}
          )
        )

      token = make_ref()
      context = %{probe: probe, test_pid: self(), token: token}

      handle =
        Exec.run_async(InlineControlledFlow, %{first: 1, second: 2, third: 3}, context,
          max_concurrency: limit
        )

      try do
        workers =
          Enum.flat_map(Enum.chunk_every(1..3, limit), fn batch ->
            started =
              Enum.map(batch, fn _index ->
                assert_receive {:inline_started, ^token, value, worker}, 1_000
                {value, worker, Process.monitor(worker)}
              end)

            assert Agent.get(probe, & &1.max) == limit

            for {_value, worker, _monitor} <- Enum.reverse(started) do
              send(worker, {:release, token})
            end

            started
          end)

        assert Exec.await(handle) == {:ok, %{values: [1, 2, 3]}}
        assert Agent.get(probe, & &1) == %{max: limit, running: 0}
        assert Enum.map(workers, &elem(&1, 0)) |> Enum.sort() == [1, 2, 3]

        for {value, worker, monitor} <- workers do
          assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
          assert_received {:inline_finished, ^token, ^value}
        end

        refute_received {:inline_started, ^token, _value, _worker}
        refute_received {:inline_finished, ^token, _value}
      after
        Exec.cancel(handle)
      end
    end
  end

  test "supports Flow module options and validates policy values" do
    assert Exec.run(AsyncMathFlow, %{value: 3}) == {:ok, %{value: 4}}
    flow = FlowFixtures.math_flow!()
    assert Exec.run(flow, %{value: 3}) == Exec.run(flow, %{value: 3}, %{}, [])

    assert {:ok, execution} = Exec.start(flow, %{value: 3})
    assert execution.options[:max_concurrency] == 8

    assert Exec.run(flow, %{value: 3}, %{}, timeout: 100) == {:ok, %{value: 8}}

    assert {:error, %InvalidExecutionError{details: %{option: :timeout, value: :soon}}} =
             Exec.run(flow, %{value: 3}, %{}, timeout: :soon)

    assert {:error, %InvalidExecutionError{details: %{option: :timeout}}} =
             Exec.start(flow, %{value: 3}, %{}, timeout: 100)

    assert {:error, %InvalidExecutionError{details: %{option: :max_continuations}}} =
             Exec.start(flow, %{value: 3}, %{}, max_continuations: 1)

    assert {:error, %InvalidExecutionError{details: %{option: :async}}} =
             Exec.run(flow, %{value: 3}, %{}, async: true)

    assert {:error, %InvalidExecutionError{details: %{option: :max_concurrency}}} =
             Exec.run(flow, %{value: 3}, %{}, max_concurrency: 0)

    assert {:error, %InvalidExecutionError{message: "run options must be a keyword list"}} =
             Exec.run(flow, %{}, %{}, :not_options)

    assert {:error, %InvalidExecutionError{message: "run options must be a keyword list"}} =
             Exec.run(flow, %{}, %{}, [{:timeout, 10}, :not_an_option])
  end

  test "accepts complete-chain options for Actions and Action Instructions" do
    assert Exec.run(Add, %{value: 1}, %{}, max_concurrency: 2) == {:ok, %{value: 2}}

    instruction = Instruction.new!(target: Add, params: %{value: 1})

    assert Exec.run(instruction, %{}, %{}, max_concurrency: 2) == {:ok, %{value: 2}}

    assert {:error, %InvalidInputError{details: %{option: :max_concurrency}}} =
             Exec.run(Add, %{value: 1}, %{}, max_concurrency: 0)

    assert {:error, %InvalidInputError{details: %{option: :max_continuations}}} =
             Exec.run(Add, %{value: 1}, %{}, max_continuations: -1)

    assert {:error, %InvalidExecutionError{details: %{option: :max_continuations}}} =
             Exec.run(FlowFixtures.math_flow!(), %{value: 1}, %{}, max_continuations: 10_001)
  end

  test "defaults the complete-call continuation limit to 256" do
    assert Options.continuation_limit([], Jido.Action.Error) == {:ok, 256}
    assert Options.continuation_limit([], Jido.Flow.Error) == {:ok, 256}
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

  test "includes executable resolution in the complete-call timeout" do
    key = {BlockingDescriptorAction, :owner}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

    caller =
      spawn(fn ->
        result = Exec.run(BlockingDescriptorAction, %{}, %{}, timeout: 100)
        send(self_or_owner(), {:descriptor_result, result})
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)

    assert_receive {:descriptor_started, descriptor_process}, 1_000
    refute descriptor_process == caller

    assert_receive {:descriptor_result, {:error, %ActionTimeoutError{timeout: 100}}}, 1_000
    assert_process_stops(descriptor_process)
  end

  test "keeps continuation resolution under the current Action timeout owner" do
    key = {BlockingFlowDescriptor, :owner}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

    assert {:error,
            %ActionTimeoutError{
              timeout: 100,
              details: %{action: ContinueToBlockingFlowDescriptor}
            }} =
             Exec.run(ContinueToBlockingFlowDescriptor, %{}, %{}, timeout: 100)

    assert_received {:continuation_flow_descriptor_started, descriptor_process}
    assert_process_stops(descriptor_process)
  end

  test "does not infer timeout ownership from an unrelated flow helper" do
    key = {BlockingActionDescriptorWithFlowHelper, :owner}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

    assert {:error,
            %ActionTimeoutError{
              timeout: 100,
              details: %{action: ContinueToBlockingActionDescriptor}
            }} =
             Exec.run(ContinueToBlockingActionDescriptor, %{}, %{}, timeout: 100)

    assert_received {:continuation_action_descriptor_started, descriptor_process}
    assert_process_stops(descriptor_process)
  end

  test "accepts a timeout above the native receive limit" do
    assert Exec.run(Add, %{value: 1}, %{}, timeout: 5_000_000_000) ==
             {:ok, %{value: 2}}
  end

  test "normalizes Task Supervisor capacity failures for finite and infinite calls" do
    instance = Module.concat(__MODULE__, CapacityLimitedJido)
    task_supervisor = Module.concat(instance, TaskSupervisor)

    start_supervised!(
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor, max_children: 0},
        id: task_supervisor
      )
    )

    for opts <- [[jido: instance], [jido: instance, timeout: 1_000]] do
      assert {:error,
              %Jido.Action.Error.ExecutionFailureError{
                message: "action execution process could not start",
                details: %{reason: :max_children, task_supervisor: ^task_supervisor}
              }} = Exec.run(Add, %{value: 1}, %{}, opts)
    end
  end

  test "a zero timeout dispatches no work for every executable form" do
    for {form, {target, input, context}} <-
          ExecFixtures.blocking_execution_forms(BlockingFlow, self()) do
      case Exec.run(target, input, context, timeout: 0) do
        {:error, %ActionTimeoutError{timeout: 0}}
        when form in [:action, :action_instruction, :flow_module, :flow_instruction] ->
          :ok

        {:error, %FlowTimeoutError{timeout: 0}}
        when form in [:flow_value, :subflow] ->
          :ok
      end

      refute_received {:blocking_flow_node_started, _worker}
    end
  end

  test "a Flow timeout stops concurrent workers" do
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
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    refute Process.alive?(pid)
  end

  defp self_or_owner do
    :persistent_term.get({BlockingDescriptorAction, :owner})
  end

  test "continue runs dependent waves in order" do
    flow =
      Flow.new!(
        name: "ordered_continue_waves",
        components: [
          Step.new!(
            name: "first",
            action: ExecFixtures.BlockingAction,
            params: %{value: :first}
          ),
          Step.new!(
            name: "second",
            action: ExecFixtures.BlockingAction,
            params: %{value: Ref.result("first", :value)}
          )
        ],
        output: Ref.result("second")
      )

    assert {:ok, execution} =
             Exec.start(flow, %{}, %{test_pid: self()}, max_concurrency: 2)

    task = Task.async(fn -> Exec.continue(execution) end)

    assert_receive {:blocking_flow_node_started, first_worker}, 1_000
    send(first_worker, :finish)

    assert_receive {:blocking_flow_node_started, second_worker}, 1_000
    send(second_worker, :finish)

    assert {:ok, completed} = Task.await(task, 1_000)
    assert Exec.result(completed) == {:ok, %{value: :first}}
  end

  test "aggregates failures from one concurrent wave" do
    ref = make_ref()

    flow =
      Flow.new!(
        name: "native_multiple_failures",
        components: [
          Step.new!(
            name: "first",
            action: GatedErrorAction,
            params: %{message: "first failure"}
          ),
          Step.new!(
            name: "second",
            action: GatedErrorAction,
            params: %{message: "second failure"}
          )
        ],
        output: %{first: Ref.result("first"), second: Ref.result("second")}
      )

    assert {:ok, execution} =
             Exec.start(flow, %{}, %{owner: self(), ref: ref}, max_concurrency: 2)

    task = Task.async(fn -> Exec.wave(execution) end)

    try do
      workers =
        for _ <- 1..2 do
          assert_receive {^ref, :ready, worker}, 1_000
          worker
        end

      Enum.each(workers, &send(&1, {ref, :fail}))
      assert {:ok, runnables, execution} = Task.await(task)
      assert Enum.all?(runnables, &(&1.status == :failed))
      assert Exec.status(execution) == :failed

      assert {:error, %FlowExecutionFailureError{failures: failures}} = Exec.result(execution)
      assert Enum.map(failures, & &1.node) |> Enum.sort() == ["first", "second"]
      assert Enum.all?(failures, &is_integer(&1.runnable_id))
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "does not leak Runic's handled-runnable warning" do
    flow =
      Flow.new!(
        name: "quiet_handled_failure",
        components: [
          Step.new!(
            name: "failure",
            action: ControlledErrorAction,
            params: %{message: "expected failure"}
          )
        ],
        output: Ref.result("failure")
      )

    {result, log} = with_log(fn -> Exec.run(flow) end)

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "expected failure"}} =
             result

    refute log =~ "Runnable failed for node"
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
