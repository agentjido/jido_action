defmodule Jido.ExecTimeoutTaskSupervisorTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureIO

  alias Jido.Action.Error
  alias Jido.Exec

  @moduletag :capture_log

  describe "Task.Supervisor async_nolink + yield/shutdown pattern" do
    test "action completes successfully before timeout" do
      defmodule FastAction do
        use Jido.Action, name: "fast_action"

        def run(_params, _context) do
          {:ok, %{completed: true}}
        end
      end

      result =
        Exec.__test_execute_action_with_timeout__(FastAction, %{}, %{}, 1000, log_level: :info)

      assert {:ok, %{completed: true}} = result
    end

    test "action times out and returns timeout error" do
      defmodule SlowAction do
        use Jido.Action, name: "slow_action"

        def run(_params, _context) do
          Process.sleep(200)
          {:ok, %{completed: true}}
        end
      end

      result =
        Exec.__test_execute_action_with_timeout__(SlowAction, %{}, %{}, 50, log_level: :info)

      assert {:error, %Error.TimeoutError{} = error} = result
      assert error.timeout == 50
      assert error.message =~ "timed out after 50ms"
      assert error.details[:action] == SlowAction

      # Verify no stray messages in mailbox
      refute_receive _, 100
    end

    test "timeout error has concise message without params/context" do
      defmodule TimeoutMessageAction do
        use Jido.Action, name: "timeout_message_action"

        def run(_params, _context) do
          Process.sleep(200)
          {:ok, %{}}
        end
      end

      large_params = %{secret: "should_not_be_in_message", data: String.duplicate("x", 1000)}
      large_context = %{sensitive: "data", more: String.duplicate("y", 1000)}

      result =
        Exec.__test_execute_action_with_timeout__(
          TimeoutMessageAction,
          large_params,
          large_context,
          50, log_level: :info)

      assert {:error, %Error.TimeoutError{} = error} = result

      # Message should be concise and not include params/context
      assert error.message =~ "timed out after 50ms"
      refute error.message =~ "should_not_be_in_message"
      refute error.message =~ "sensitive"

      # Details should only contain timeout and action (not full params/context)
      assert error.details[:timeout] == 50
      assert error.details[:action] == TimeoutMessageAction
      refute Map.has_key?(error.details, :params)
      refute Map.has_key?(error.details, :context)
    end

    test "preserves group_leader for IO routing" do
      defmodule IOAction do
        use Jido.Action, name: "io_action"

        def run(_params, _context) do
          # IO should work and be captured properly
          IO.puts("test output")
          {:ok, %{io_worked: true}}
        end
      end

      io =
        capture_io(fn ->
          result =
            Exec.__test_execute_action_with_timeout__(IOAction, %{}, %{}, 1000, log_level: :info)

          assert {:ok, %{io_worked: true}} = result
        end)

      assert io =~ "test output"
    end

    test "child tasks are cleaned up on timeout with brutal_kill" do
      # This test verifies that when Task.shutdown with :brutal_kill is used,
      # child processes spawned by the action are also terminated.
      # Task.async links child to parent, so :brutal_kill will cascade.

      test_pid = self()

      defmodule ChildSpawningAction do
        use Jido.Action, name: "child_spawning_action"

        def run(_params, context) do
          # Spawn a linked child task
          child_pid =
            spawn_link(fn ->
              send(context.test_pid, {:child_started, self()})
              Process.sleep(10_000)
            end)

          send(context.test_pid, {:parent_has_child, child_pid})

          # Parent sleeps longer than timeout
          Process.sleep(10_000)
          {:ok, %{done: true}}
        end
      end

      # Execute the action with short timeout
      spawn_link(fn ->
        result =
          Exec.__test_execute_action_with_timeout__(
            ChildSpawningAction,
            %{},
            %{test_pid: test_pid},
            50,
            log_level: :info
          )

        send(test_pid, {:result, result})
      end)

      # Get child PID
      child_pid =
        receive do
          {:parent_has_child, pid} -> pid
        after
          200 -> nil
        end

      # Wait for timeout result
      assert_receive {:result, {:error, %Error.TimeoutError{}}}, 500

      if child_pid do
        # Give Task.Supervisor time to kill processes
        Process.sleep(150)

        # Child should be terminated when parent is killed with :brutal_kill
        refute Process.alive?(child_pid),
               "Child process should be killed when parent times out"
      end
    end

    test "handles action that exits abnormally" do
      defmodule ExitingAction do
        use Jido.Action, name: "exiting_action"

        def run(_params, _context) do
          Process.exit(self(), :shutdown)
          {:ok, %{}}
        end
      end

      result =
        Exec.__test_execute_action_with_timeout__(ExitingAction, %{}, %{}, 1000, log_level: :info)

      assert {:error, %Error.ExecutionFailureError{} = error} = result
      assert error.message =~ "Task exited"
    end

    test "handles action that is killed" do
      defmodule KillableAction do
        use Jido.Action, name: "killable_action"

        def run(_params, _context) do
          Process.exit(self(), :kill)
          {:ok, %{}}
        end
      end

      result =
        Exec.__test_execute_action_with_timeout__(KillableAction, %{}, %{}, 1000,
          log_level: :info
        )

      assert {:error, %Error.ExecutionFailureError{} = error} = result
      assert error.message =~ "Task exited"
    end

    test "multiple concurrent timeouts don't interfere" do
      defmodule ConcurrentAction do
        use Jido.Action, name: "concurrent_action"

        def run(params, _context) do
          Process.sleep(params[:delay])
          {:ok, %{id: params[:id]}}
        end
      end

      test_pid = self()

      # Spawn multiple actions concurrently
      for i <- 1..5 do
        spawn(fn ->
          result =
            Exec.__test_execute_action_with_timeout__(
              ConcurrentAction,
              %{id: i, delay: i * 50},
              %{},
              75,
              log_level: :info
            )

          send(test_pid, {:result, i, result})
        end)
      end

      # Collect results
      results =
        for _ <- 1..5 do
          receive do
            {:result, id, result} -> {id, result}
          after
            2000 -> flunk("Did not receive all results")
          end
        end

      # Actions 1 should succeed, 2-5 should timeout
      results_map = Map.new(results)
      assert {:ok, %{id: 1}} = results_map[1]

      for i <- 2..5 do
        assert {:error, %Error.TimeoutError{}} = results_map[i]
      end
    end

    test "no process leaks after timeout" do
      defmodule LeakTestAction do
        use Jido.Action, name: "leak_test_action"

        def run(_params, _context) do
          Process.sleep(200)
          {:ok, %{}}
        end
      end

      initial_count = length(Process.list())

      # Run several actions that timeout
      for _ <- 1..10 do
        Exec.__test_execute_action_with_timeout__(LeakTestAction, %{}, %{}, 50, log_level: :info)
      end

      # Wait for cleanup
      Process.sleep(100)

      final_count = length(Process.list())
      # Should be roughly the same (allow small variance for system processes)
      assert_in_delta initial_count, final_count, 5
    end
  end
end
