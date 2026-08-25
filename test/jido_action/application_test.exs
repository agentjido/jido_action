defmodule JidoActionTest.Action.ApplicationTest do
  use ExUnit.Case, async: true

  test "starts the shared Action Task Supervisor" do
    assert {:ok, _apps} = Application.ensure_all_started(:jido_action)

    children = Supervisor.which_children(JidoAction.Supervisor)

    assert {Jido.Action.TaskSupervisor, supervisor, :supervisor, [Task.Supervisor]} =
             Enum.find(children, &(elem(&1, 0) == Jido.Action.TaskSupervisor))

    assert {Jido.Exec.ConcurrencySupervisor, concurrency_supervisor, :supervisor,
            [DynamicSupervisor]} =
             Enum.find(children, &(elem(&1, 0) == Jido.Exec.ConcurrencySupervisor))

    assert {Jido.Exec.ConcurrencyRegistry, registry, :supervisor, [Registry]} =
             Enum.find(children, &(elem(&1, 0) == Jido.Exec.ConcurrencyRegistry))

    assert Process.whereis(Jido.Action.TaskSupervisor) == supervisor
    assert Process.whereis(Jido.Exec.ConcurrencySupervisor) == concurrency_supervisor
    assert Process.whereis(Jido.Exec.ConcurrencyRegistry) == registry
  end
end
