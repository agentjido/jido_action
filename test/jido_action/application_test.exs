defmodule Jido.Action.ApplicationTest do
  use ExUnit.Case, async: true

  test "starts the shared Action Task Supervisor" do
    assert {:ok, _apps} = Application.ensure_all_started(:jido_action)

    assert [
             {Jido.Action.TaskSupervisor, supervisor, :supervisor, [Task.Supervisor]}
           ] = Supervisor.which_children(JidoAction.Supervisor)

    assert Process.whereis(Jido.Action.TaskSupervisor) == supervisor
  end
end
