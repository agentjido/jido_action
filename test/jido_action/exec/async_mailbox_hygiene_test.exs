defmodule JidoTest.Exec.AsyncMailboxHygieneTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Exec
  alias JidoTest.TestActions.BasicAction
  alias JidoTest.TestActions.DelayAction

  @moduletag :capture_log

  describe "await/2 mailbox hygiene" do
    test "cleans monitor and result messages on success" do
      capture_log(fn ->
        async_ref = Exec.run_async(BasicAction, %{value: 10})

        assert is_reference(async_ref.monitor_ref)
        assert {:ok, %{value: 10}} = Exec.await(async_ref, 1_000)
        assert_no_async_residue(async_ref.ref, async_ref.pid)
      end)
    end

    test "cleans monitor and result messages on timeout" do
      capture_log(fn ->
        async_ref = Exec.run_async(DelayAction, %{delay: 200}, %{}, timeout: 500)

        assert {:error, %Jido.Action.Error.TimeoutError{}} = Exec.await(async_ref, 1)
        Process.sleep(20)
        assert_no_async_residue(async_ref.ref, async_ref.pid)
      end)
    end

    test "supports legacy async_ref without monitor_ref and still cleans messages" do
      capture_log(fn ->
        parent = self()
        ref = make_ref()

        {:ok, pid} =
          Task.start(fn ->
            Process.sleep(20)
            send(parent, {:action_async_result, ref, {:ok, %{legacy: true}}})
          end)

        assert {:ok, %{legacy: true}} = Exec.await(%{ref: ref, pid: pid}, 500)
        assert_no_async_residue(ref, pid)
      end)
    end
  end

  defp assert_no_async_residue(ref, pid) do
    refute_receive {:action_async_result, ^ref, _}, 50
    refute_receive {:DOWN, _, :process, ^pid, _}, 50
  end
end
