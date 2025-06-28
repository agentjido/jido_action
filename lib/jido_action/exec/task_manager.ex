defmodule Jido.Exec.TaskManager do
  @moduledoc """
  Task management functionality for Jido.Exec.
  
  This module handles:
  - Action execution with timeout management
  - Task group creation and cleanup
  - Process spawning and monitoring for action execution
  """

  use ExDbug, enabled: false

  alias Jido.Action.Error

  require Logger
  require OK

  @type action :: module()
  @type params :: map()
  @type context :: map()
  @type run_opts :: [timeout: non_neg_integer()]

  @default_timeout 5000

  # Helper functions to get configuration values with fallbacks
  defp get_default_timeout,
    do: Application.get_env(:jido_action, :default_timeout, @default_timeout)

  @spec execute_action_with_timeout(action(), params(), context(), non_neg_integer(), run_opts(), function()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_action_with_timeout(action, params, context, timeout, opts, execute_action_fn)

  def execute_action_with_timeout(action, params, context, 0, opts, execute_action_fn) do
    execute_action_fn.(action, params, context, opts)
  end

  def execute_action_with_timeout(action, params, context, timeout, opts, execute_action_fn)
      when is_integer(timeout) and timeout > 0 do
    parent = self()
    ref = make_ref()

    dbug("Starting action with timeout", action: action, timeout: timeout)

    # Create a temporary task group for this execution
    {:ok, task_group} =
      Task.Supervisor.start_child(
        Jido.Action.TaskSupervisor,
        fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:shutdown} -> :ok
          end
        end
      )

    # Add task_group to context so Actions can use it
    enhanced_context = Map.put(context, :__task_group__, task_group)

    # Get the current process's group leader
    current_gl = Process.group_leader()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        # Use the parent's group leader to ensure IO is properly captured
        Process.group_leader(self(), current_gl)

          result =
            try do
              dbug("Executing action in task", action: action, pid: self())
              result = execute_action_fn.(action, params, enhanced_context, opts)
              dbug("Action execution completed", action: action, result: result)
              result
          catch
            kind, reason ->
              stacktrace = __STACKTRACE__
              dbug("Action execution caught error", action: action, kind: kind, reason: reason)

              {:error,
               Error.execution_error(
                 "Caught #{kind}: #{inspect(reason)}",
                 %{kind: kind, reason: reason, action: action},
                 stacktrace
               )}
          end

        send(parent, {:done, ref, result})
      end)

    result =
      receive do
        {:done, ^ref, result} ->
          dbug("Received action result", action: action, result: result)
          cleanup_task_group(task_group)
          Process.demonitor(monitor_ref, [:flush])
          result

        {:DOWN, ^monitor_ref, :process, ^pid, :killed} ->
          dbug("Task was killed", action: action)
          cleanup_task_group(task_group)
          {:error, Error.execution_error("Task was killed")}

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          dbug("Task exited unexpectedly", action: action, reason: reason)
          cleanup_task_group(task_group)
          {:error, Error.execution_error("Task exited: #{inspect(reason)}")}
      after
        timeout ->
          dbug("Action timed out", action: action, timeout: timeout)
          cleanup_task_group(task_group)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^monitor_ref, :process, ^pid, _} -> :ok
          after
            0 -> :ok
          end

          {:error,
           Error.timeout(
             "Action #{inspect(action)} timed out after #{timeout}ms. This could be due to:
1. The action is taking too long to complete (current timeout: #{timeout}ms)
2. The action is stuck in an infinite loop
3. The action's return value doesn't match the expected format ({:ok, map()} | {:ok, map(), directive} | {:error, reason})
4. An unexpected error occurred without proper error handling
5. The action may be using unsafe IO operations (IO.inspect, etc).

Debug info:
- Action module: #{inspect(action)}
- Params: #{inspect(params)}
- Context: #{inspect(Map.drop(context, [:__task_group__]))}"
           )}
      end

    result
  end

  def execute_action_with_timeout(action, params, context, _timeout, opts, execute_action_fn) do
    execute_action_with_timeout(action, params, context, get_default_timeout(), opts, execute_action_fn)
  end

  @doc """
  Cleanup task group and all associated processes.
  """
  @spec cleanup_task_group(pid()) :: :ok
  def cleanup_task_group(task_group) do
    send(task_group, {:shutdown})

    Process.exit(task_group, :kill)

    Task.Supervisor.children(Jido.Action.TaskSupervisor)
    |> Enum.filter(fn pid ->
      case Process.info(pid, :group_leader) do
        {:group_leader, ^task_group} -> true
        _ -> false
      end
    end)
    |> Enum.each(&Process.exit(&1, :kill))
  end
end
