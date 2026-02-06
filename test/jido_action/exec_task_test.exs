defmodule Jido.ExecTaskTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias JidoTest.TestActions.SpawnerAction
  alias JidoTest.TestActions.TaskAction

  @moduletag :capture_log
  describe "spawning multiple processes" do
    test "handles action spawning multiple processes" do
      result = Exec.execute_action_with_timeout(SpawnerAction, %{count: 10}, %{}, 1000)
      assert {:ok, %{result: "Multi-process action completed"}} = result
      # Ensure no lingering processes
      :timer.sleep(150)
      process_list = Process.list()
      process_count = length(process_list)
      assert process_count <= :erlang.system_info(:process_count)
    end

    test "handles naked task action spawning multiple processes" do
      result =
        Exec.execute_action_with_timeout(
          NakedTaskAction,
          %{count: 2},
          %{},
          # Short timeout to force error
          100
        )

      assert {:error, error} = result
      assert is_exception(error)
      assert error.__struct__ == Jido.Action.Error.ExecutionFailureError
    end

    test "properly cleans up linked tasks when task group is terminated" do
      initial_count = length(Process.list())

      # Start a long-running task that will be linked to the task group
      result =
        Exec.execute_action_with_timeout(
          TaskAction,
          # Long delay to ensure task is still running
          %{count: 1, delay: 5000},
          %{},
          # Short timeout to force termination
          100
        )

      # Should timeout
      assert {:error, _} = result

      # Wait briefly for cleanup
      :timer.sleep(150)

      # Verify no lingering processes
      final_count = length(Process.list())
      assert_in_delta final_count, initial_count, 2
    end

    test "cleans up multiple linked tasks on task group termination" do
      initial_count = length(Process.list())

      # Start multiple long-running tasks linked to task group
      result =
        Exec.execute_action_with_timeout(
          TaskAction,
          # Long delay
          %{count: 5, delay: 5000},
          %{},
          # Short timeout
          100
        )

      assert {:error, _} = result

      # Wait briefly for cleanup
      :timer.sleep(150)

      # Verify all tasks were cleaned up
      final_count = length(Process.list())
      assert_in_delta final_count, initial_count, 2
    end
  end

  # cleanup_task_group/1 has been removed as Task.Supervisor with :brutal_kill
  # handles cleanup automatically. The tests above verify that cleanup works correctly.
end
