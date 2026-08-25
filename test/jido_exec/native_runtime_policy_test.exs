defmodule JidoActionTest.Exec.NativeRuntimePolicyTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  defmodule LoggerMetadataAction do
    use Jido.Action, name: "native_logger_metadata_action"

    @impl Jido.Action
    def run(params, %{test_pid: test_pid}) do
      send(test_pid, {:action_logger_metadata, params.id, Logger.metadata()})
      {:ok, params}
    end
  end

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Exec.FlowFailureError
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias Jido.Instruction

  alias JidoActionTest.ExecFixtures.{
    AsyncMathFlow,
    ConcurrencyProbeAction,
    ControlledErrorAction
  }

  alias JidoActionTest.ExecFixtures
  alias JidoActionTest.FlowFixtures
  alias JidoActionTest.TestActions.{Add, EchoParamsAction, KillingAction, RecorderAction}
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

    assert {:error, %InvalidInputError{details: %{option: :timeout}}} =
             Exec.run(flow, %{value: 3}, %{}, timeout: 100)

    assert {:error, %InvalidInputError{details: %{option: :async}}} =
             Exec.run(flow, %{value: 3}, %{}, async: :yes)

    assert {:error, %InvalidInputError{details: %{option: :max_concurrency}}} =
             Exec.run(flow, %{value: 3}, %{}, max_concurrency: 0)

    assert {:error, %InvalidInputError{message: "run options must be a keyword list"}} =
             Exec.run(flow, %{}, %{}, :not_options)
  end

  test "rejects Flow run options for Actions and Instructions" do
    assert {:error, %InvalidInputError{details: %{executable_type: :action}}} =
             Exec.run(Add, %{value: 1}, %{}, async: true)

    instruction = Instruction.new!(action: Add, params: %{value: 1})

    assert {:error, %InvalidInputError{details: %{executable_type: :instruction}}} =
             Exec.run(instruction, %{}, %{}, async: true)
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

    assert {:error, %FlowFailureError{failures: failures}} = Exec.result(execution)
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

  test "contains a killed Action inside a native runnable" do
    flow =
      Flow.new!(
        name: "native_action_exit",
        components: [Step.new!(name: "kill", action: KillingAction)],
        output: Ref.result("kill")
      )

    assert {:error,
            %ExecutionFailureError{
              message: "action execution process exited",
              details: %{node: "kill", action: KillingAction, reason: :killed}
            }} = Exec.run(flow)
  end

  test "validates step selection and terminal operations" do
    flow =
      Flow.new!(
        name: "selection_validation",
        components: [Step.new!(name: "echo", action: EchoParamsAction)],
        output: Ref.result("echo")
      )

    assert {:ok, execution} = Exec.start(flow)

    assert {:error, %InvalidInputError{message: "flow execution is not complete"}} =
             Exec.result(execution)

    assert {:error, %InvalidInputError{message: "flow runnable is not ready"}} =
             Exec.step(execution, -1)

    assert {:error,
            %InvalidInputError{message: "flow runnable must be a ready Runnable or runnable ID"}} =
             Exec.step(execution, :bad)

    assert {:ok, %Runnable{}, execution} = Exec.step(execution)
    assert Exec.status(execution) == :succeeded

    assert {:error, %InvalidInputError{message: "flow execution is not running"}} =
             Exec.step(execution)

    assert {:error, %InvalidInputError{message: "flow execution is not running"}} =
             Exec.wave(execution)

    assert {:ok, ^execution} = Exec.continue(execution)
  end

  defp receive_probe_start(probe) do
    assert_receive {ConcurrencyProbeAction, :started, ^probe, side, worker}, 1_000
    {side, worker}
  end
end
