defmodule JidoActionTest.Exec.SupervisorTest do
  use JidoActionTest.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Exec.Runtime

  test "starts the application Task Supervisor" do
    assert {:ok, _apps} = Application.ensure_all_started(:jido_action)
    assert is_pid(Process.whereis(Jido.Exec.TaskSupervisor))
  end

  test "resolves global and Jido instance Task Supervisors" do
    instance = unique_module("JidoInstance")
    instance_task_supervisor = Module.concat(instance, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: instance_task_supervisor})

    assert Runtime.task_supervisor_name([]) == Jido.Exec.TaskSupervisor
    assert Runtime.task_supervisor_name(jido: nil) == Jido.Exec.TaskSupervisor
    assert Runtime.task_supervisor_name(jido: instance) == instance_task_supervisor

    assert Runtime.task_supervisor([]) == {:ok, Jido.Exec.TaskSupervisor}
    assert Runtime.task_supervisor(jido: instance) == {:ok, instance_task_supervisor}
  end

  test "does not fall back when a Jido instance Task Supervisor is absent" do
    instance = unique_module("MissingJidoInstance")
    instance_task_supervisor = Module.concat(instance, TaskSupervisor)

    assert {:error,
            %InvalidInputError{
              message: "Task Supervisor is not running",
              details: %{jido: ^instance, task_supervisor: ^instance_task_supervisor}
            }} = Runtime.task_supervisor(jido: instance)
  end

  test "rejects an invalid direct routing value" do
    assert_raise ArgumentError, ~r/:jido must be an atom or nil/, fn ->
      Runtime.task_supervisor_name(jido: "invalid")
    end
  end
end
