defmodule Jido.Tools.LuaEvalSupervisionTest do
  use ExUnit.Case, async: false

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

      assert_receive {:done, ^caller, {:error, %{type: :timeout, timeout_ms: 200}}}, 500
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

      assert_receive {:done, ^caller, {:error, %{type: :timeout, timeout_ms: 200}}}, 500
    end
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
end
