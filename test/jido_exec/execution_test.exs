defmodule Jido.Exec.ExecutionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Exec.{Execution, NodeResult}
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}

  alias JidoTest.TestActions.{
    Add,
    DelayedEchoAction,
    DelayedErrorAction,
    EchoParamsAction,
    KillingAction,
    Multiply,
    RecorderAction
  }

  def count_transform(value, phase, _opts) do
    key = {__MODULE__, phase}
    Process.put(key, Process.get(key, 0) + 1)
    {:ok, value}
  end

  describe "start/4 and step/2" do
    test "pauses before the first node and executes one named node at a time" do
      flow = linear_flow()
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
      flow = wide_flow(64)
      expected = Enum.map(1..64, &node_name/1)

      assert {:ok, execution} = Exec.start(flow)
      assert Exec.ready(execution) == expected

      assert {:ok, %NodeResult{node: "node_0001"}, execution} = Exec.step(execution)
      assert Exec.ready(execution) == tl(expected)
    end

    test "rejects a node that is not ready without changing the execution" do
      assert {:ok, execution} = Exec.start(linear_flow(), %{value: 3})

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
               Exec.start(linear_flow(), %{value: 3}, %{}, timeout: 100)

      assert message =~ "unknown run option"
      assert details.option == :timeout
    end

    test "rejects further steps after execution succeeds" do
      assert {:ok, execution} = Exec.start(linear_flow(), %{value: 3})
      assert {:ok, execution} = Exec.continue(execution)

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.step(execution)

      assert message == "flow execution is not running"
      assert details.status == :succeeded
    end
  end

  describe "wave/1" do
    test "executes only the nodes that were ready when the wave started" do
      flow = diamond_flow(RecorderAction)
      context = %{test_pid: self()}

      assert {:ok, execution} = Exec.start(flow, %{}, context)
      assert Exec.ready(execution) == ["left", "right"]

      assert {:ok, results, execution} = Exec.wave(execution)
      assert Enum.map(results, & &1.node) == ["left", "right"]
      assert Enum.all?(results, &(&1.status == :ok))
      assert Exec.ready(execution) == ["merge"]

      assert_receive {RecorderAction, %{side: :left}}
      assert_receive {RecorderAction, %{side: :right}}
      refute_receive {RecorderAction, %{left: _, right: _}}

      assert {:ok, [%NodeResult{node: "merge"}], execution} = Exec.wave(execution)
      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == {:ok, %{left: :left, right: :right}}
    end

    @tag timeout: 5_000
    test "uses the stored asynchronous execution options" do
      flow = diamond_flow(DelayedEchoAction, 100)

      assert {:ok, serial} = Exec.start(flow)
      assert {_, serial_ms} = timed(fn -> Exec.wave(serial) end)

      assert {:ok, parallel} = Exec.start(flow, %{}, %{}, async: true, max_concurrency: 2)
      assert {{:ok, results, _execution}, parallel_ms} = timed(fn -> Exec.wave(parallel) end)

      assert Enum.map(results, & &1.node) == ["left", "right"]
      assert parallel_ms < serial_ms * 0.75
    end

    test "settles internal multi-parent joins before exposing the next Flow node" do
      assert {:ok, execution} = Exec.start(diamond_flow(EchoParamsAction))
      assert {:ok, _results, execution} = Exec.wave(execution)

      assert Exec.ready(execution) == ["merge"]
      refute inspect(Exec.ready(execution)) =~ "Runic"
    end
  end

  describe "failure behavior" do
    @tag capture_log: true
    test "records a failed node, skips dependents, and keeps independent work ready" do
      flow =
        Flow.new!(
          name: "step_failure",
          nodes: [
            Node.new!(
              name: :fail,
              action: DelayedErrorAction,
              input: %{sleep_ms: Ref.value(0), message: Ref.value("failed first")}
            ),
            Node.new!(
              name: :dependent,
              action: RecorderAction,
              input: %{value: Ref.result(:fail, :value)}
            ),
            Node.new!(
              name: :independent,
              action: RecorderAction,
              input: %{side: Ref.value(:independent)}
            )
          ],
          return: Ref.result(:independent)
        )

      assert {:ok, execution} = Exec.start(flow, %{}, %{test_pid: self()})
      assert Exec.ready(execution) == ["fail", "independent"]

      assert {:ok,
              %NodeResult{
                node: "fail",
                status: :error,
                output: nil,
                error: %ExecutionFailureError{message: "failed first"}
              }, execution} = Exec.step(execution, "fail")

      assert Exec.status(execution) == :running
      assert_ready_cache(execution, ["independent"])

      assert {:ok, %NodeResult{status: :ok}, execution} =
               Exec.step(execution, "independent")

      assert_receive {RecorderAction, %{side: :independent}}
      refute_receive {RecorderAction, %{value: _}}

      assert Exec.status(execution) == :failed
      assert_ready_cache(execution, [])

      assert {:error, %ExecutionFailureError{message: "failed first", details: details}} =
               Exec.result(execution)

      assert details.node == "fail"
    end

    @tag capture_log: true
    test "can continue a paused execution from another process" do
      flow =
        Flow.new!(
          name: "cross_process_failure",
          nodes: [
            Node.new!(
              name: :fail,
              action: DelayedErrorAction,
              input: %{sleep_ms: Ref.value(0), message: Ref.value("task failure")}
            )
          ],
          return: Ref.result(:fail)
        )

      assert {:ok, execution} = Exec.start(flow)

      assert {:ok, %NodeResult{status: :error}, execution} =
               Task.async(fn -> Exec.step(execution) end) |> Task.await()

      assert {:error, %ExecutionFailureError{message: "task failure"}} = Exec.result(execution)
    end

    @tag capture_log: true
    test "keeps wave results and final failure selection in canonical node order" do
      flow =
        Flow.new!(
          name: "canonical_failures",
          nodes: [
            Node.new!(
              name: :zeta,
              action: DelayedErrorAction,
              input: %{sleep_ms: Ref.value(0), message: Ref.value("zeta failed")}
            ),
            Node.new!(
              name: :alpha,
              action: DelayedErrorAction,
              input: %{sleep_ms: Ref.value(0), message: Ref.value("alpha failed")}
            )
          ],
          return: %{alpha: Ref.result(:alpha), zeta: Ref.result(:zeta)}
        )

      assert {:ok, execution} = Exec.start(flow)
      assert {:ok, results, execution} = Exec.wave(execution)
      assert Enum.map(results, & &1.node) == ["alpha", "zeta"]
      assert Enum.all?(results, &(&1.status == :error))
      assert Exec.status(execution) == :failed
      assert_ready_cache(execution, [])

      assert {:error, %ExecutionFailureError{message: "alpha failed", details: details}} =
               Exec.result(execution)

      assert details.node == "alpha"
    end

    @tag capture_log: true
    test "converts a killed async worker into its named failure without losing its sibling" do
      flow =
        Flow.new!(
          name: "async_worker_exit",
          nodes: [
            Node.new!(
              name: :success,
              action: EchoParamsAction,
              input: %{value: Ref.value(:applied)}
            ),
            Node.new!(name: :kill, action: KillingAction)
          ],
          return: %{kill: Ref.result(:kill), success: Ref.result(:success)}
        )

      assert {:ok, execution} =
               Exec.start(flow, %{}, %{}, async: true, max_concurrency: 2)

      {:trap_exit, trap_exit} = Process.info(self(), :trap_exit)
      assert {:ok, [failed, succeeded], execution} = Exec.wave(execution)
      assert Process.info(self(), :trap_exit) == {:trap_exit, trap_exit}

      assert %NodeResult{
               node: "kill",
               status: :error,
               output: nil,
               error: %ExecutionFailureError{
                 message: "flow node task exited",
                 details: %{node: "kill", reason: :killed}
               }
             } = failed

      assert %NodeResult{
               node: "success",
               status: :ok,
               output: %{value: :applied},
               error: nil
             } = succeeded

      assert Exec.status(execution) == :failed
      assert_ready_cache(execution, [])
      assert Exec.result(execution) == {:error, failed.error}
    end
  end

  describe "continue/1 and run/4 alignment" do
    test "continues to completion with the same result as run/4" do
      flow = diamond_flow(EchoParamsAction)

      assert {:ok, execution} = Exec.start(flow)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == Exec.run(flow)
    end

    test "validates input and output once and caches the final result" do
      module = unique_module("CountedStepFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "counted_step_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({unquote(__MODULE__), :count_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({unquote(__MODULE__), :count_transform, [:output]})

          flow do
            step(:echo, unquote(EchoParamsAction), %{value: input(:value)})
            return(result(:echo))
          end
        end
      )

      assert {:ok, execution} = Exec.start(module, %{value: 3})
      assert Process.get({__MODULE__, :input}) == 1
      assert Process.get({__MODULE__, :output}, 0) == 0

      assert {:ok, execution} = Exec.continue(execution)
      assert Process.get({__MODULE__, :output}) == 1

      assert Exec.result(execution) == {:ok, %{value: 3}}
      assert Exec.result(execution) == {:ok, %{value: 3}}
      assert Process.get({__MODULE__, :output}) == 1
    end

    test "treats a nested Flow as one outer node" do
      nested_module = unique_module("NestedStepFlow")

      create_module(
        nested_module,
        quote do
          use Jido.Flow, name: "nested_step_flow"

          flow do
            step(:add, unquote(Add), %{value: input(:value), amount: value(1)})
            return(result(:add))
          end
        end
      )

      outer =
        Flow.new!(
          name: "outer_step_flow",
          nodes: [
            Node.new!(
              name: :nested,
              action: nested_module,
              input: %{value: Ref.input(:value)}
            )
          ],
          return: Ref.result(:nested)
        )

      assert {:ok, execution} = Exec.start(outer, %{value: 3})
      assert Exec.ready(execution) == ["nested"]

      assert {:ok, %NodeResult{node: "nested", output: %{value: 4}}, execution} =
               Exec.step(execution)

      assert Exec.status(execution) == :succeeded
      assert Exec.result(execution) == {:ok, %{value: 4}}
    end
  end

  describe "scheduler caches" do
    test "builds static indexes once and keeps the ready map and list in sync" do
      assert {:ok, execution} = Exec.start(diamond_flow(EchoParamsAction))

      node_names = Map.fetch!(execution, :node_names)
      node_positions = Map.fetch!(execution, :node_positions)

      assert node_names == MapSet.new(["left", "merge", "right"])
      assert node_positions == %{"left" => 0, "right" => 1, "merge" => 2}
      assert_ready_cache(execution, ["left", "right"])

      assert {:ok, %NodeResult{node: "left"}, execution} = Exec.step(execution)
      assert Map.fetch!(execution, :node_names) === node_names
      assert Map.fetch!(execution, :node_positions) === node_positions
      assert_ready_cache(execution, ["right"])

      assert {:ok, [%NodeResult{node: "right"}], execution} = Exec.wave(execution)
      assert Map.fetch!(execution, :node_names) === node_names
      assert Map.fetch!(execution, :node_positions) === node_positions
      assert_ready_cache(execution, ["merge"])

      assert {:ok, %NodeResult{node: "merge"}, execution} = Exec.step(execution)
      assert Exec.status(execution) == :succeeded
      assert Map.fetch!(execution, :node_names) === node_names
      assert Map.fetch!(execution, :node_positions) === node_positions
      assert_ready_cache(execution, [])
    end

    @tag timeout: 120_000
    test "steps through a 1,000-node serial flow one node at a time" do
      assert {:ok, execution} = Exec.start(serial_flow(1_000))

      execution =
        for index <- 1..1_000, reduce: execution do
          current ->
            name = node_name(index)
            assert Exec.ready(current) == [name]
            assert {:ok, %NodeResult{node: ^name}, next} = Exec.step(current)
            next
        end

      assert Exec.status(execution) == :succeeded
      assert_ready_cache(execution, [])
      assert Exec.result(execution) == {:ok, %{value: 1_000}}
    end

    @tag timeout: 120_000
    test "continues a 1,000-node serial flow to completion" do
      assert {:ok, execution} = Exec.start(serial_flow(1_000))
      assert {:ok, execution} = Exec.continue(execution)

      assert execution.revision == 1_000
      assert Exec.status(execution) == :succeeded
      assert_ready_cache(execution, [])
      assert Exec.result(execution) == {:ok, %{value: 1_000}}
    end

    @tag timeout: 120_000
    test "ready cost is isolated from total node count" do
      assert {:ok, small} = Exec.start(serial_flow(2))
      assert {:ok, large} = Exec.start(serial_flow(1_000))
      assert Exec.ready(small) == ["node_0001"]
      assert Exec.ready(large) == ["node_0001"]

      ready_reductions(small, 100)
      ready_reductions(large, 100)

      small_reductions = ready_reductions(small, 10_000)
      large_reductions = ready_reductions(large, 10_000)

      assert large_reductions <= trunc(small_reductions * 1.1) + 2_000
    end
  end

  defp linear_flow do
    Flow.new!(
      name: "step_linear",
      nodes: [
        Node.new!(
          name: :add,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        ),
        Node.new!(
          name: :multiply,
          action: Multiply,
          input: %{value: Ref.result(:add, :value), amount: Ref.value(2)}
        )
      ],
      return: Ref.result(:multiply)
    )
  end

  defp diamond_flow(action, sleep_ms \\ nil) do
    branch_input = fn side ->
      %{side: Ref.value(side)}
      |> maybe_put_sleep(sleep_ms)
    end

    Flow.new!(
      name: "step_diamond",
      nodes: [
        Node.new!(name: :right, action: action, input: branch_input.(:right)),
        Node.new!(name: :left, action: action, input: branch_input.(:left)),
        Node.new!(
          name: :merge,
          action: EchoParamsAction,
          input: %{
            left: Ref.result(:left, :side),
            right: Ref.result(:right, :side)
          }
        )
      ],
      return: Ref.result(:merge)
    )
  end

  defp maybe_put_sleep(input, nil), do: input
  defp maybe_put_sleep(input, sleep_ms), do: Map.put(input, :sleep_ms, Ref.value(sleep_ms))

  defp wide_flow(node_count) do
    names = Enum.map(1..node_count, &node_name/1)

    nodes =
      names
      |> Enum.reverse()
      |> Enum.map(fn name ->
        Node.new!(name: name, action: EchoParamsAction, input: %{name: Ref.value(name)})
      end)

    return = Map.new(names, &{&1, Ref.result(&1)})
    Flow.new!(name: "wide_step_flow", nodes: nodes, return: return)
  end

  defp serial_flow(node_count) do
    nodes =
      Enum.map(1..node_count, fn index ->
        input =
          if index == 1 do
            %{value: Ref.value(0), amount: Ref.value(1)}
          else
            %{value: Ref.result(node_name(index - 1), :value), amount: Ref.value(1)}
          end

        Node.new!(name: node_name(index), action: Add, input: input)
      end)

    Flow.new!(
      name: "serial_step_flow_#{node_count}",
      nodes: nodes,
      return: Ref.result(node_name(node_count))
    )
  end

  defp node_name(index) do
    "node_#{index |> Integer.to_string() |> String.pad_leading(4, "0")}"
  end

  defp assert_ready_cache(execution, expected) do
    assert Exec.ready(execution) == expected
    assert Map.fetch!(execution, :ready_nodes) == expected
    assert execution.ready |> Map.keys() |> Enum.sort() == expected
  end

  defp ready_reductions(execution, iterations) do
    {:reductions, before_reductions} = Process.info(self(), :reductions)

    assert Enum.reduce(1..iterations, 0, fn _, count ->
             count + length(Exec.ready(execution))
           end) == iterations

    {:reductions, after_reductions} = Process.info(self(), :reductions)
    after_reductions - before_reductions
  end

  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started_at}
  end
end
