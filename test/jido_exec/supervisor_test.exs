defmodule JidoActionTest.Exec.SupervisorTest do
  use JidoActionTest.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Exec.Supervisor, as: ExecSupervisor

  test "starts the Exec supervision tree" do
    assert {:ok, _apps} = Application.ensure_all_started(:jido_action)

    children = Supervisor.which_children(Jido.Exec.Supervisor)

    assert {Jido.Exec.TaskSupervisor, task_supervisor, :supervisor, [Task.Supervisor]} =
             Enum.find(children, &(elem(&1, 0) == Jido.Exec.TaskSupervisor))

    assert {Jido.Exec.ConcurrencySupervisor, concurrency_supervisor, :supervisor,
            [DynamicSupervisor]} =
             Enum.find(children, &(elem(&1, 0) == Jido.Exec.ConcurrencySupervisor))

    assert {Jido.Exec.ConcurrencyRegistry, registry, :supervisor, [Registry]} =
             Enum.find(children, &(elem(&1, 0) == Jido.Exec.ConcurrencyRegistry))

    assert Process.whereis(Jido.Exec.Supervisor)
    assert Process.whereis(Jido.Exec.TaskSupervisor) == task_supervisor
    assert Process.whereis(Jido.Exec.ConcurrencySupervisor) == concurrency_supervisor
    assert Process.whereis(Jido.Exec.ConcurrencyRegistry) == registry
  end

  test "resolves global and Jido instance Task Supervisors" do
    instance = unique_module("JidoInstance")
    instance_task_supervisor = Module.concat(instance, TaskSupervisor)
    start_supervised!({Task.Supervisor, name: instance_task_supervisor})

    assert ExecSupervisor.task_supervisor_name([]) == Jido.Exec.TaskSupervisor
    assert ExecSupervisor.task_supervisor_name(jido: nil) == Jido.Exec.TaskSupervisor
    assert ExecSupervisor.task_supervisor_name(jido: instance) == instance_task_supervisor

    assert ExecSupervisor.task_supervisor([]) == {:ok, Jido.Exec.TaskSupervisor}
    assert ExecSupervisor.task_supervisor(jido: instance) == {:ok, instance_task_supervisor}
  end

  test "does not fall back when a Jido instance Task Supervisor is absent" do
    instance = unique_module("MissingJidoInstance")
    instance_task_supervisor = Module.concat(instance, TaskSupervisor)

    assert {:error,
            %InvalidInputError{
              message: "Task Supervisor is not running",
              details: %{jido: ^instance, task_supervisor: ^instance_task_supervisor}
            }} = ExecSupervisor.task_supervisor(jido: instance)
  end
end
