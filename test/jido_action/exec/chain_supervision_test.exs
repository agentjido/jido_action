defmodule JidoTest.Exec.ChainSupervisionTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec.Chain
  alias JidoTest.TestActions.Add
  alias JidoTest.TestActions.Multiply

  describe "async chain supervision" do
    test "returns an unlinked task so caller is isolated from task crashes" do
      task =
        Chain.chain([Add], %{value: 1},
          async: true,
          interrupt_check: fn -> raise "interrupt check crashed" end
        )

      assert %Task{} = task

      caller_links =
        self()
        |> Process.info(:links)
        |> elem(1)

      refute task.pid in caller_links
      assert catch_exit(Task.await(task, 1_000))
      assert Process.alive?(self())
    end

    test "routes async chain task through the jido instance supervisor" do
      start_supervised!({Task.Supervisor, name: ChainTenant.TaskSupervisor})

      task = Chain.chain([Add, Multiply], %{value: 2, amount: 3}, async: true, jido: ChainTenant)

      assert %Task{} = task
      assert task.pid in Task.Supervisor.children(ChainTenant.TaskSupervisor)
      assert {:ok, %{value: 15, amount: 3}} = Task.await(task, 1_000)
    end

    test "raises when async chain jido supervisor is not running" do
      assert_raise ArgumentError, ~r/Instance task supervisor.*is not running/, fn ->
        Chain.chain([Add], %{value: 1}, async: true, jido: Missing.Chain.Instance)
      end
    end
  end
end
