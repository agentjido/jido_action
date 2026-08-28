defmodule JidoActionTest.Exec.AsyncMailboxHygieneTest do
  use JidoActionTest.Case, async: false

  alias Jido.Exec
  alias JidoActionTest.Fixtures.Actions.Add
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  test "await removes result and monitor messages after success" do
    handle = Exec.run_async(Add, %{value: 1})
    assert {:ok, %{value: 2}} = Exec.await(handle, 1_000)
    assert_no_async_messages(handle)
  end

  test "await removes result and monitor messages after timeout" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, _worker}, 1_000
    assert {:error, %Jido.Exec.Error.AsyncTimeoutError{}} = Exec.await(handle, 0)
    assert_no_async_messages(handle)
  end

  test "cancel removes result and monitor messages" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, _worker}, 1_000
    assert :ok = Exec.cancel(handle)
    assert_no_async_messages(handle)
  end

  test "await accepts a result that follows a normal process signal" do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor_ref = Process.monitor(pid)
    ref = make_ref()

    handle = %{
      ref: ref,
      pid: pid,
      owner: self(),
      monitor_ref: monitor_ref,
      token: :atomics.new(1, signed: false)
    }

    send(self(), {:DOWN, monitor_ref, :process, pid, :normal})
    send(self(), {:jido_exec_async_result, ref, pid, {:ok, %{value: 2}}})

    assert {:ok, %{value: 2}} = Exec.await(handle, 1_000)
    assert_no_async_messages(handle)
    send(pid, :stop)
  end

  defp assert_no_async_messages(handle) do
    ref = handle.ref
    pid = handle.pid
    monitor_ref = handle.monitor_ref
    refute_received {:jido_exec_async_result, ^ref, ^pid, _result}
    refute_received {:DOWN, ^monitor_ref, :process, ^pid, _reason}
  end
end
