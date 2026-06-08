defmodule Jido.Tools.LuaEvalSupervisionTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Tools.LuaEval

  @context %{}

  describe "task supervision" do
    test "runs Lua execution under Jido.Action.TaskSupervisor" do
      baseline_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()
      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :run ->
              result = LuaEval.run(%{code: "while true do end", timeout_ms: 200}, @context)
              send(parent, {:done, self(), result})
          end
        end)

      assert_receive {:ready, ^caller}
      send(caller, :run)
      assert_new_supervisor_child(baseline_children)

      assert_receive {:done, ^caller, {:error, %Error.TimeoutError{} = error}}, 500
      assert error.timeout == 200
      assert error.details[:reason] == %{type: :timeout, timeout_ms: 200}
    end

    test "does not link Lua task to the caller process" do
      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :run ->
              result = LuaEval.run(%{code: "while true do end", timeout_ms: 200}, @context)
              send(parent, {:done, self(), result})
          end
        end)

      assert_receive {:ready, ^caller}
      baseline_links = caller |> Process.info(:links) |> elem(1) |> MapSet.new()
      send(caller, :run)
      Process.sleep(30)

      links_during_execution = caller |> Process.info(:links) |> elem(1) |> MapSet.new()
      assert links_during_execution == baseline_links

      assert_receive {:done, ^caller, {:error, %Error.TimeoutError{} = error}}, 500
      assert error.timeout == 200
      assert error.details[:reason] == %{type: :timeout, timeout_ms: 200}
    end

    test "direct Lua execution applies the default heap cap" do
      baseline_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()
      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :run ->
              result = LuaEval.run(%{code: "while true do end", timeout_ms: 200}, @context)
              send(parent, {:done, self(), result})
          end
        end)

      assert_receive {:ready, ^caller}
      send(caller, :run)
      lua_pid = await_new_supervisor_child(baseline_children)

      assert_default_heap_cap(lua_pid)

      assert_receive {:done, ^caller, {:error, %Error.TimeoutError{} = error}}, 500
      assert error.timeout == 200
    end

    test "kills Lua worker when the caller exits before the Lua timeout" do
      baseline_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()
      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :run ->
              result = LuaEval.run(%{code: "while true do end", timeout_ms: 5_000}, @context)
              send(parent, {:done, self(), result})
          end
        end)

      assert_receive {:ready, ^caller}
      send(caller, :run)
      lua_pid = await_new_supervisor_child(baseline_children)

      Process.exit(caller, :kill)

      refute_process_alive(lua_pid)
      refute_receive {:done, ^caller, _result}, 100
    end

    test "Exec timeout does not leave an orphaned Lua worker" do
      baseline_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()

      assert {:error, %Error.TimeoutError{}} =
               Exec.run(
                 LuaEval,
                 %{code: "while true do end", timeout_ms: 5_000},
                 %{},
                 timeout: 50
               )

      assert_supervisor_children_return_to(baseline_children)
    end
  end

  defp assert_default_heap_cap(pid, attempts_left \\ 20)

  defp assert_default_heap_cap(pid, 0) do
    flunk("Expected Lua worker #{inspect(pid)} to have the default max heap cap")
  end

  defp assert_default_heap_cap(pid, attempts_left) do
    expected_size = default_heap_words()

    case Process.info(pid, :max_heap_size) do
      {:max_heap_size, %{kill: true, size: ^expected_size}} ->
        :ok

      {:max_heap_size, _max_heap_size} ->
        Process.sleep(10)
        assert_default_heap_cap(pid, attempts_left - 1)

      nil ->
        flunk("Lua worker #{inspect(pid)} exited before its heap cap could be inspected")
    end
  end

  defp default_heap_words do
    (64 * 1024 * 1024)
    |> div(:erlang.system_info(:wordsize))
    |> max(1)
  end

  defp assert_new_supervisor_child(baseline_children, attempts_left \\ 10)

  defp assert_new_supervisor_child(_baseline_children, 0) do
    flunk("Expected a Lua task under Jido.Action.TaskSupervisor, but none was observed")
  end

  defp assert_new_supervisor_child(baseline_children, attempts_left) do
    current_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()

    if MapSet.size(MapSet.difference(current_children, baseline_children)) > 0 do
      :ok
    else
      Process.sleep(10)
      assert_new_supervisor_child(baseline_children, attempts_left - 1)
    end
  end

  defp await_new_supervisor_child(baseline_children, attempts_left \\ 20)

  defp await_new_supervisor_child(_baseline_children, 0) do
    flunk("Expected a Lua task under Jido.Action.TaskSupervisor, but none was observed")
  end

  defp await_new_supervisor_child(baseline_children, attempts_left) do
    current_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()
    new_children = MapSet.difference(current_children, baseline_children) |> MapSet.to_list()

    case new_children do
      [pid | _] ->
        pid

      [] ->
        Process.sleep(10)
        await_new_supervisor_child(baseline_children, attempts_left - 1)
    end
  end

  defp refute_process_alive(pid, attempts_left \\ 20)

  defp refute_process_alive(pid, 0) do
    flunk("Expected Lua worker #{inspect(pid)} to exit")
  end

  defp refute_process_alive(pid, attempts_left) do
    if Process.alive?(pid) do
      Process.sleep(10)
      refute_process_alive(pid, attempts_left - 1)
    else
      refute Process.alive?(pid)
    end
  end

  defp assert_supervisor_children_return_to(baseline_children, attempts_left \\ 20)

  defp assert_supervisor_children_return_to(baseline_children, 0) do
    current_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()

    flunk("""
    Expected Lua supervisor children to return to baseline.
    Baseline: #{inspect(baseline_children)}
    Current: #{inspect(current_children)}
    """)
  end

  defp assert_supervisor_children_return_to(baseline_children, attempts_left) do
    current_children = Task.Supervisor.children(Jido.Action.TaskSupervisor) |> MapSet.new()

    if MapSet.equal?(current_children, baseline_children) do
      :ok
    else
      Process.sleep(10)
      assert_supervisor_children_return_to(baseline_children, attempts_left - 1)
    end
  end
end
