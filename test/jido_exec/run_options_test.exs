defmodule JidoActionTest.Exec.RunOptionsTest do
  use ExUnit.Case, async: true

  defmodule LoggerMetadataAction do
    use Jido.Action, name: "logger_metadata_action"

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
  alias Jido.Flow.{Choice, Condition, Node, Ref}
  alias Jido.Instruction

  alias JidoActionTest.ExecFixtures.{
    AsyncMathFlow,
    ConcurrencyProbeAction,
    ControlledErrorAction,
    NestedSerialProbeFlow
  }

  alias JidoActionTest.ExecFixtures
  alias JidoActionTest.FlowFixtures

  alias JidoActionTest.TestActions.{
    Add,
    EchoParamsAction
  }

  describe "run/4 options" do
    test "preserves caller Logger metadata in asynchronous Flow nodes" do
      flow =
        Flow.new!(
          name: "async_logger_metadata",
          nodes: [
            Node.new!(
              name: :metadata,
              action: LoggerMetadataAction,
              input: %{id: Ref.value(:metadata)}
            )
          ],
          return: Ref.result(:metadata)
        )

      metadata_key = :jido_test_request_id
      Logger.metadata([{metadata_key, "request-123"}])

      assert {:ok, %{id: :metadata}} =
               Exec.run(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 1)

      assert_receive {:action_logger_metadata, :metadata, metadata}
      assert metadata[metadata_key] == "request-123"
    end

    @tag timeout: 5_000
    test "keeps an independent sibling asynchronous beside a Choice" do
      probe = start_probe()

      flow =
        Flow.new!(
          name: "choice_async_sibling",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: ConcurrencyProbeAction,
                  input: probe_input(:choice)
                ]
              ],
              fallback: [action: EchoParamsAction]
            ),
            Node.new!(
              name: :sibling,
              action: ConcurrencyProbeAction,
              input: probe_input(:sibling)
            )
          ],
          return: %{choice: Ref.result(:route, :side), sibling: Ref.result(:sibling, :side)}
        )

      test_pid = self()

      task =
        Task.async(fn ->
          Exec.run(flow, %{}, %{probe: probe, test_pid: test_pid},
            async: true,
            max_concurrency: 2
          )
        end)

      assert [:choice, :sibling] == probe |> receive_parallel_starts() |> Enum.sort()
      assert {:ok, %{choice: :choice, sibling: :sibling}} = Task.await(task)
    end

    @tag timeout: 5_000
    test "passes parent run options into a selected nested Flow" do
      probe = start_probe()

      flow =
        Flow.new!(
          name: "choice_parent_run_options",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: NestedSerialProbeFlow,
                  input: %{
                    probe: Ref.context(:probe),
                    test_pid: Ref.context(:test_pid)
                  }
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      test_pid = self()

      task =
        Task.async(fn ->
          Exec.run(flow, %{}, %{probe: probe, test_pid: test_pid},
            async: true,
            max_concurrency: 2
          )
        end)

      assert [:left, :right] == probe |> receive_parallel_starts() |> Enum.sort()
      assert {:ok, %{left: :left, right: :right}} = Task.await(task)
    end

    @tag timeout: 5_000
    test "runs independent flow branches concurrently when async is enabled" do
      probe = start_probe()
      flow = ExecFixtures.probe_diamond_flow()
      test_pid = self()

      task =
        Task.async(fn ->
          Exec.run(flow, %{}, %{probe: probe, test_pid: test_pid},
            async: true,
            max_concurrency: 2
          )
        end)

      assert [:left, :right] == probe |> receive_parallel_starts() |> Enum.sort()
      assert {:ok, %{left: :left, right: :right}} = Task.await(task)
    end

    test "run/3 and run/4 with empty options are equivalent" do
      flow = FlowFixtures.math_flow!()

      assert Exec.run(flow, %{value: 3}, %{}) == Exec.run(flow, %{value: 3}, %{}, [])
    end

    @tag capture_log: true
    test "returns async branch failures by flow node order" do
      flow =
        Flow.new!(
          name: "async_failure_order",
          nodes: [
            Node.new!(
              name: :first,
              action: ControlledErrorAction,
              input: %{
                block: Ref.value(true),
                key: Ref.value(:first),
                message: Ref.value("first failure"),
                test_pid: Ref.context(:test_pid)
              }
            ),
            Node.new!(
              name: :second,
              action: ControlledErrorAction,
              input: %{
                key: Ref.value(:second),
                message: Ref.value("second failure"),
                test_pid: Ref.context(:test_pid)
              }
            )
          ],
          return: Ref.result(:first)
        )

      test_pid = self()

      task =
        Task.async(fn ->
          Exec.run(flow, %{}, %{test_pid: test_pid}, async: true, max_concurrency: 2)
        end)

      assert_receive {ControlledErrorAction, :started, :first, first_worker}, 1_000
      assert_receive {ControlledErrorAction, :started, :second, second_worker}, 1_000

      second_monitor = Process.monitor(second_worker)
      assert_receive {:DOWN, ^second_monitor, :process, ^second_worker, _reason}, 1_000
      send(first_worker, {:release, :first})

      assert {:error,
              %FlowFailureError{
                failures: [
                  %{node: "first", error: %ExecutionFailureError{message: "first failure"}},
                  %{node: "second", error: %ExecutionFailureError{message: "second failure"}}
                ]
              }} =
               Task.await(task)
    end

    test "executes Flow modules with runtime options" do
      assert {:ok, %{value: 4}} = Exec.run(AsyncMathFlow, %{value: 3}, %{}, async: true)
    end

    test "scopes the concurrency limiter to an active execution operation" do
      flow =
        Flow.new!(
          name: "limiter_lifecycle",
          nodes: [
            Node.new!(
              name: :blocking,
              action: ExecFixtures.BlockingAction,
              input: %{test_pid: Ref.context(:test_pid)}
            )
          ],
          return: Ref.result(:blocking)
        )

      assert {:ok, execution} =
               Exec.start(flow, %{}, %{test_pid: self()}, async: true, max_concurrency: 2)

      assert Jido.Exec.ConcurrencyLimiter.whereis(execution.id) == nil

      task = Task.async(fn -> Exec.step(execution, "blocking") end)

      assert_receive {:blocking_flow_node_started, worker}, 1_000
      limiter = Jido.Exec.ConcurrencyLimiter.whereis(execution.id)
      assert Process.alive?(limiter)
      send(worker, :finish)

      assert {:ok, _node_result, execution} = Task.await(task)
      assert Exec.status(execution) == :succeeded
      assert Jido.Exec.ConcurrencyLimiter.whereis(execution.id) == nil
    end

    test "rejects unknown Flow run options" do
      flow = FlowFixtures.math_flow!()

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{}, timeout: 100)

      assert message =~ "unknown run option"
      assert details.option == :timeout
    end

    test "rejects invalid Flow run option values" do
      flow = FlowFixtures.math_flow!()

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{}, async: :yes)

      assert message =~ "async option must be a boolean"
      assert details.option == :async

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{}, max_concurrency: 0)

      assert message =~ "max_concurrency option must be a positive integer"
      assert details.option == :max_concurrency

      assert {:error, %InvalidInputError{message: "run options must be a keyword list"}} =
               Exec.run(flow, %{}, %{}, :not_options)
    end

    test "rejects Flow run options for action and instruction executables" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(Add, %{value: 1}, %{}, async: true)

      assert message =~ "run options are only supported for flows"
      assert details.executable_type == :action

      instruction = Instruction.new!(action: Add, params: %{value: 1})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(instruction, %{}, %{}, async: true)

      assert message =~ "run options are only supported for flows"
      assert details.executable_type == :instruction
    end
  end

  defp start_probe do
    start_supervised!({Agent, fn -> %{max: 0, running: 0} end})
  end

  defp probe_input(side) do
    %{
      probe: Ref.context(:probe),
      side: Ref.value(side),
      test_pid: Ref.context(:test_pid)
    }
  end

  defp receive_parallel_starts(probe) do
    starts = Enum.map(1..2, fn _index -> receive_probe_start(probe) end)
    assert Agent.get(probe, & &1.max) == 2
    release_probe_starts(probe, starts)
  end

  defp receive_probe_start(probe) do
    assert_receive {ConcurrencyProbeAction, :started, ^probe, side, worker}, 1_000
    {side, worker}
  end

  defp release_probe_starts(probe, starts) do
    Enum.each(starts, fn {_side, worker} -> send(worker, {:release, probe}) end)
    Enum.map(starts, &elem(&1, 0))
  end
end
