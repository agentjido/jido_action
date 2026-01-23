defmodule JidoTest.Exec.InstanceIsolationTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Exec
  alias Jido.Exec.Supervisors
  alias JidoTest.TestActions.BasicAction
  alias JidoTest.TestActions.DelayAction

  @moduletag :capture_log

  describe "Jido.Exec.Supervisors.task_supervisor/1" do
    test "returns global supervisor when no jido option" do
      assert Supervisors.task_supervisor([]) == Jido.Action.TaskSupervisor
    end

    test "returns global supervisor when jido: nil" do
      assert Supervisors.task_supervisor(jido: nil) == Jido.Action.TaskSupervisor
    end

    test "returns instance supervisor when jido: option provided" do
      start_supervised!({Task.Supervisor, name: MyApp.Jido.TaskSupervisor})

      assert Supervisors.task_supervisor(jido: MyApp.Jido) == MyApp.Jido.TaskSupervisor
    end

    test "raises when instance supervisor is not running" do
      assert_raise ArgumentError, ~r/Instance task supervisor.*is not running/, fn ->
        Supervisors.task_supervisor(jido: Missing.Instance)
      end
    end

    test "raises when jido option is not an atom" do
      assert_raise ArgumentError, ~r/Expected :jido option to be an atom/, fn ->
        Supervisors.task_supervisor(jido: "not_an_atom")
      end
    end

    test "raises when opts is not a keyword list" do
      assert_raise ArgumentError, ~r/Expected opts to be a keyword list/, fn ->
        Supervisors.task_supervisor(%{jido: MyApp.Jido})
      end
    end
  end

  describe "Jido.Exec.Supervisors.task_supervisor_name/1" do
    test "returns global supervisor name when no jido option" do
      assert Supervisors.task_supervisor_name([]) == Jido.Action.TaskSupervisor
    end

    test "returns instance supervisor name without validation" do
      # Does not raise even if supervisor not running
      assert Supervisors.task_supervisor_name(jido: NotRunning.Instance) ==
               NotRunning.Instance.TaskSupervisor
    end
  end

  describe "Jido.Exec.run/4 with jido: option" do
    test "uses global supervisor by default" do
      capture_log(fn ->
        # Should work with no jido option (uses global)
        assert {:ok, %{value: 42}} = Exec.run(BasicAction, %{value: 42}, %{}, timeout: 100)
      end)
    end

    test "routes to instance supervisor when jido: provided" do
      # Start instance supervisor
      sup_name = TestInstance.TaskSupervisor
      start_supervised!({Task.Supervisor, name: sup_name})

      capture_log(fn ->
        # Should use the instance supervisor
        assert {:ok, %{value: 42}} =
                 Exec.run(BasicAction, %{value: 42}, %{}, jido: TestInstance, timeout: 100)
      end)
    end

    test "returns error when instance supervisor not running" do
      # The exception is caught by Exec.run's error handling and converted to an error tuple
      capture_log(fn ->
        assert {:error, error} =
                 Exec.run(BasicAction, %{value: 42}, %{},
                   jido: NonExistent.Instance,
                   timeout: 100
                 )

        assert Exception.message(error) =~ "Instance task supervisor"
        assert Exception.message(error) =~ "is not running"
      end)
    end

    test "task runs under correct instance supervisor" do
      sup_name = IsolatedInstance.TaskSupervisor
      start_supervised!({Task.Supervisor, name: sup_name})

      capture_log(fn ->
        # Run an action that takes some time so we can inspect
        async_ref = Exec.run_async(DelayAction, %{delay: 100}, %{}, jido: IsolatedInstance)

        # Check the task is running under the instance supervisor
        children = Task.Supervisor.children(sup_name)
        refute Enum.empty?(children)

        # The task should be a child of instance supervisor
        assert async_ref.pid in children

        # Wait for completion
        Exec.await(async_ref, 500)
      end)
    end
  end

  describe "Jido.Exec.run_async/4 with jido: option" do
    test "routes async tasks to instance supervisor" do
      sup_name = AsyncInstance.TaskSupervisor
      start_supervised!({Task.Supervisor, name: sup_name})

      capture_log(fn ->
        async_ref = Exec.run_async(BasicAction, %{value: 1}, %{}, jido: AsyncInstance)

        # Verify task is under instance supervisor
        children = Task.Supervisor.children(sup_name)
        assert async_ref.pid in children

        assert {:ok, %{value: 1}} = Exec.await(async_ref)
      end)
    end

    test "raises when instance supervisor not running for async" do
      assert_raise ArgumentError, ~r/Instance task supervisor.*is not running/, fn ->
        Exec.run_async(BasicAction, %{value: 42}, %{}, jido: Missing.Async.Instance)
      end
    end
  end

  describe "isolation guarantees" do
    test "separate instances have separate supervisors" do
      start_supervised!({Task.Supervisor, name: TenantA.TaskSupervisor})
      start_supervised!({Task.Supervisor, name: TenantB.TaskSupervisor})

      capture_log(fn ->
        # Run actions under different instances
        ref_a = Exec.run_async(DelayAction, %{delay: 100}, %{}, jido: TenantA)
        ref_b = Exec.run_async(DelayAction, %{delay: 100}, %{}, jido: TenantB)

        # Verify they're under different supervisors
        children_a = Task.Supervisor.children(TenantA.TaskSupervisor)
        children_b = Task.Supervisor.children(TenantB.TaskSupervisor)

        assert ref_a.pid in children_a
        refute ref_a.pid in children_b

        assert ref_b.pid in children_b
        refute ref_b.pid in children_a

        # Cleanup
        Exec.await(ref_a, 500)
        Exec.await(ref_b, 500)
      end)
    end

    test "no cross-tenant task visibility" do
      start_supervised!({Task.Supervisor, name: Isolated1.TaskSupervisor})
      start_supervised!({Task.Supervisor, name: Isolated2.TaskSupervisor})

      capture_log(fn ->
        # Run action under Isolated1
        ref = Exec.run_async(DelayAction, %{delay: 100}, %{}, jido: Isolated1)

        # Should NOT appear in Isolated2's supervisor
        children_2 = Task.Supervisor.children(Isolated2.TaskSupervisor)
        refute ref.pid in children_2

        Exec.await(ref, 500)
      end)
    end
  end

  describe "timeout: 0 behavior (no supervised task)" do
    test "works with instance option even with timeout: 0" do
      # timeout: 0 runs directly without spawning a supervised task
      start_supervised!({Task.Supervisor, name: DirectRun.TaskSupervisor})

      capture_log(fn ->
        # This should still work - the supervisor is validated even if not used
        assert {:ok, %{value: 42}} =
                 Exec.run(BasicAction, %{value: 42}, %{}, jido: DirectRun, timeout: 0)
      end)
    end
  end
end
