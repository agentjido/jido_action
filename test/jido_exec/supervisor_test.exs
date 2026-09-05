defmodule JidoActionTest.Exec.SupervisorTest do
  use JidoActionTest.Case, async: true

  alias Jido.Exec
  alias Jido.Exec.Runtime

  test "starts the application Task Supervisor" do
    assert {:ok, _apps} = Application.ensure_all_started(:jido_action)
    assert is_pid(Process.whereis(Jido.Exec.TaskSupervisor))
  end

  test "declares the global Task Supervisor as a registered application process" do
    assert Jido.Exec.TaskSupervisor in Application.spec(:jido_action, :registered)
  end

  test "uses the package supervisor by default" do
    assert Runtime.task_supervisor([]) == {:ok, Jido.Exec.TaskSupervisor}
  end

  test "removes the host-name helper" do
    assert Code.ensure_loaded?(Exec)
    refute function_exported?(Exec, :task_supervisor_name, 1)
  end
end
