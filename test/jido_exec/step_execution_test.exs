defmodule Jido.Exec.StepExecutionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Exec
  alias Jido.Exec.{Execution, NodeResult}
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.ExecFixtures.ConcurrencyProbeAction
  alias JidoTest.ExecutionFixtures
  alias JidoTest.TestActions.{Add, EchoParamsAction, RecorderAction}

  describe "start/4 and step/2" do
    test "pauses before the first node and executes one named node at a time" do
      flow = ExecutionFixtures.linear_flow()
      context = %{trace_id: "secret-context"}

      assert {:ok, %Execution{} = execution} = Exec.start(flow, [value: 3], context)
      assert Exec.status(execution) == :running
      assert Exec.ready(execution) == ["add"]

      inspected = inspect(execution)
      refute inspected =~ "secret-context"
      refute inspected =~ "Runic"

      assert {:error, %InvalidInputError{message: "flow execution is not complete"}} =
               Exec.result(execution)

      assert {:ok,
              %NodeResult{
                node: "add",
                status: :ok,
                output: %{value: 4},
                error: nil,
                attempt: 1
              }, execution} = Exec.step(execution, "add")

      assert Exec.status(execution) == :running
      assert Exec.ready(execution) == ["multiply"]

      assert {:ok, %NodeResult{node: "multiply", output: %{value: 8}}, execution} =
               Exec.step(execution)

      assert Exec.status(execution) == :succeeded
      assert Exec.ready(execution) == []
      assert Exec.result(execution) == {:ok, %{value: 8}}
    end

    test "uses canonical node order for ready nodes and default selection" do
      flow =
        Flow.new!(
          name: "canonical_ready",
          nodes: [
            Node.new!(name: :zeta, action: EchoParamsAction, input: %{name: Ref.value(:zeta)}),
            Node.new!(name: :alpha, action: EchoParamsAction, input: %{name: Ref.value(:alpha)})
          ],
          return: %{alpha: Ref.result(:alpha), zeta: Ref.result(:zeta)}
        )

      assert {:ok, execution} = Exec.start(flow)
      assert Exec.ready(execution) == ["alpha", "zeta"]

      assert {:ok, %NodeResult{node: "alpha"}, execution} = Exec.step(execution)
      assert Exec.ready(execution) == ["zeta"]
    end

    test "uses canonical node order for a wide ready set" do
      flow = ExecutionFixtures.wide_flow(64)
      expected = Enum.map(1..64, &ExecutionFixtures.node_name/1)

      assert {:ok, execution} = Exec.start(flow)
      assert Exec.ready(execution) == expected

      assert {:ok, %NodeResult{node: "node_0001"}, execution} = Exec.step(execution)
      assert Exec.ready(execution) == tl(expected)
    end

    test "rejects a node that is not ready without changing the execution" do
      assert {:ok, execution} = Exec.start(ExecutionFixtures.linear_flow(), %{value: 3})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.step(execution, "multiply")

      assert message == "flow node is not ready"
      assert details.node == "multiply"
      assert details.ready == ["add"]
      assert Exec.ready(execution) == ["add"]
    end

    test "rejects step-wise execution for a leaf action" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.start(Add, %{value: 3})

      assert message == "step-wise execution is only supported for flows"
      assert details.executable_type == :action
    end

    test "uses the same Flow option validation as run/4" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.start(ExecutionFixtures.linear_flow(), %{value: 3}, %{}, timeout: 100)

      assert message =~ "unknown run option"
      assert details.option == :timeout
    end

    test "rejects further steps after execution succeeds" do
      assert {:ok, execution} = Exec.start(ExecutionFixtures.linear_flow(), %{value: 3})
      assert {:ok, execution} = Exec.continue(execution)

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.step(execution)

      assert message == "flow execution is not running"
      assert details.status == :succeeded
    end

    test "rejects non-string names and terminal wave calls" do
      assert {:ok, execution} = Exec.start(ExecutionFixtures.linear_flow(), %{value: 3})

      assert {:error, %InvalidInputError{message: message, details: %{node: :add}}} =
               Exec.step(execution, :add)

      assert message == "flow node name must be a string"

      assert {:ok, execution} = Exec.continue(execution)

      assert {:error, %InvalidInputError{message: "flow execution is not running"}} =
               Exec.step(execution, "add")

      assert {:error, %InvalidInputError{message: "flow execution is not running"}} =
               Exec.wave(execution)
    end
  end

  describe "wave/1" do
    test "executes only the nodes that were ready when the wave started" do
      flow = ExecutionFixtures.diamond_flow(RecorderAction)
      context = %{test_pid: self()}

      assert {:ok, execution} = Exec.start(flow, %{}, context)
      assert Exec.ready(execution) == ["left", "right"]

      assert {:ok, results, execution} = Exec.wave(execution)
      assert Enum.map(results, & &1.node) == ["left", "right"]
      assert Enum.all?(results, &(&1.status == :ok))
      assert Exec.ready(execution) == ["merge"]

      assert_receive {RecorderAction, %{side: :left}}
      assert_receive {RecorderAction, %{side: :right}}
      refute_received {RecorderAction, %{left: _, right: _}}

      assert {:ok, [%NodeResult{node: "merge"}], execution} = Exec.wave(execution)
      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == {:ok, %{left: :left, right: :right}}
    end

    @tag timeout: 5_000
    test "uses the stored asynchronous execution options" do
      probe = start_supervised!({Agent, fn -> %{max: 0, running: 0} end})
      flow = ExecutionFixtures.probe_diamond_flow()

      assert {:ok, parallel} =
               Exec.start(flow, %{}, %{probe: probe, test_pid: self()},
                 async: true,
                 max_concurrency: 2
               )

      task = Task.async(fn -> Exec.wave(parallel) end)

      starts =
        Enum.map(1..2, fn _index ->
          assert_receive {ConcurrencyProbeAction, :started, ^probe, side, worker}, 1_000
          {side, worker}
        end)

      assert Agent.get(probe, & &1.max) == 2
      Enum.each(starts, fn {_side, worker} -> send(worker, {:release, probe}) end)

      assert {:ok, results, _execution} = Task.await(task)

      assert Enum.map(results, & &1.node) == ["left", "right"]
      assert starts |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [:left, :right]
    end

    test "settles internal multi-parent joins before exposing the next Flow node" do
      assert {:ok, execution} = Exec.start(ExecutionFixtures.diamond_flow(EchoParamsAction))
      assert {:ok, _results, execution} = Exec.wave(execution)

      assert Exec.ready(execution) == ["merge"]
      refute inspect(Exec.ready(execution)) =~ "Runic"
    end
  end
end
