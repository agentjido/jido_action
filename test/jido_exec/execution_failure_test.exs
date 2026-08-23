defmodule Jido.Exec.ExecutionFailureTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Exec.NodeResult
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.ExecFixtures.ControlledErrorAction
  alias JidoTest.ExecutionFixtures
  alias JidoTest.TestActions.{EchoParamsAction, KillingAction, RecorderAction}

  describe "failure behavior" do
    @tag capture_log: true
    test "records a failed node, skips dependents, and keeps independent work ready" do
      flow =
        Flow.new!(
          name: "step_failure",
          nodes: [
            Node.new!(
              name: :fail,
              action: ControlledErrorAction,
              input: %{message: Ref.value("failed first")}
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
      refute_received {RecorderAction, %{value: _}}

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
              action: ControlledErrorAction,
              input: %{message: Ref.value("task failure")}
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
              action: ControlledErrorAction,
              input: %{message: Ref.value("zeta failed")}
            ),
            Node.new!(
              name: :alpha,
              action: ControlledErrorAction,
              input: %{message: Ref.value("alpha failed")}
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

    @tag timeout: 5_000
    test "preserves normal caller semantics for unrelated linked exits" do
      flow =
        Flow.new!(
          name: "unrelated_link_exit",
          nodes: [Node.new!(name: :blocking, action: ExecutionFixtures.BlockingAction)],
          return: Ref.result(:blocking)
        )

      test_pid = self()

      {caller, monitor} =
        spawn_monitor(fn ->
          linked =
            spawn_link(fn ->
              receive do
                :exit_abnormally -> exit(:unrelated_link_exit)
              end
            end)

          send(test_pid, {:flow_caller_ready, linked})

          result =
            with {:ok, execution} <-
                   Exec.start(flow, %{}, %{test_pid: test_pid},
                     async: true,
                     max_concurrency: 1
                   ) do
              Exec.wave(execution)
            end

          send(test_pid, {:flow_caller_result, result})
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)

      assert_receive {:flow_caller_ready, linked}
      assert_receive {:blocking_flow_node_started, worker}
      worker_monitor = Process.monitor(worker)

      send(linked, :exit_abnormally)

      assert_receive {:DOWN, ^monitor, :process, ^caller, :unrelated_link_exit}, 1_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
      refute_received {:flow_caller_result, _result}
    end
  end

  defp assert_ready_cache(execution, expected) do
    assert Exec.ready(execution) == expected
    assert Map.fetch!(execution, :ready_nodes) == expected
    assert execution.ready |> Map.keys() |> Enum.sort() == expected
  end
end
