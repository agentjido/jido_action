defmodule Jido.Exec.ExecutionFailureTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Exec.FlowFailureError
  alias Jido.Exec.NodeResult
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias JidoTest.ExecFixtures.ControlledErrorAction
  alias JidoTest.ExecutionFixtures
  alias JidoTest.TestActions.{EchoParamsAction, KillingAction, RecorderAction}

  describe "failure behavior" do
    @tag capture_log: true
    test "stops before it dispatches independent work after a failed node" do
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

      assert Exec.status(execution) == :failed
      assert_ready_cache(execution, [])

      assert {:error, _error} = Exec.step(execution, "independent")
      refute_received {RecorderAction, %{side: :independent}}
      refute_received {RecorderAction, %{value: _}}

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
    test "stops a serial wave after its first failed node" do
      flow =
        Flow.new!(
          name: "serial_wave_failure",
          nodes: [
            Node.new!(
              name: :fail,
              action: ControlledErrorAction,
              input: %{message: Ref.value("failed first")}
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
      assert {:ok, [failed], execution} = Exec.wave(execution)
      assert failed.node == "fail"
      assert failed.status == :error
      assert Exec.status(execution) == :failed
      refute_received {RecorderAction, %{side: :independent}}
    end

    @tag capture_log: true
    test "keeps concurrent failures in canonical node order" do
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

      assert {:ok, execution} = Exec.start(flow, %{}, %{}, async: true, max_concurrency: 2)
      assert {:ok, results, execution} = Exec.wave(execution)
      assert Enum.map(results, & &1.node) == ["alpha", "zeta"]
      assert Enum.all?(results, &(&1.status == :error))
      assert Exec.status(execution) == :failed
      assert_ready_cache(execution, [])

      assert {:error,
              %FlowFailureError{
                flow: "canonical_failures",
                failures: [
                  %{node: "alpha", error: %ExecutionFailureError{message: "alpha failed"}},
                  %{node: "zeta", error: %ExecutionFailureError{message: "zeta failed"}}
                ]
              }} = Exec.result(execution)
    end

    @tag capture_log: true
    test "contains a killed Action process in serial run and step-wise paths" do
      flow =
        Flow.new!(
          name: "serial_action_exit",
          nodes: [Node.new!(name: :kill, action: KillingAction)],
          return: Ref.result(:kill)
        )

      operations = [
        run: fn -> Exec.run(flow) end,
        step: fn ->
          with {:ok, execution} <- Exec.start(flow),
               {:ok, result, _execution} <- Exec.step(execution) do
            {:error, result.error}
          end
        end,
        wave: fn ->
          with {:ok, execution} <- Exec.start(flow),
               {:ok, [result], _execution} <- Exec.wave(execution) do
            {:error, result.error}
          end
        end,
        continue: fn ->
          with {:ok, execution} <- Exec.start(flow),
               {:ok, execution} <- Exec.continue(execution) do
            Exec.result(execution)
          end
        end
      ]

      for {operation, run} <- operations do
        assert {:error,
                %ExecutionFailureError{
                  message: "action execution process exited",
                  details: details
                }} = run_in_monitored_caller(run),
               to_string(operation)

        assert details.action == KillingAction, to_string(operation)
        assert details.node == "kill", to_string(operation)
        assert details.phase == :step_execution, to_string(operation)
        assert details.reason == :killed, to_string(operation)
      end
    end

    @tag capture_log: true
    test "contains a killed Action process in an async node without losing its sibling" do
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
                 message: "action execution process exited",
                 details: %{
                   action: KillingAction,
                   node: "kill",
                   phase: :step_execution,
                   reason: :killed
                 }
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
      assert_receive {:blocking_flow_node_started, worker}, 1_000
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

  defp run_in_monitored_caller(fun) do
    owner = self()
    ref = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(owner, {ref, fun.()})
      end)

    assert_receive {^ref, result}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    result
  end
end
