defmodule JidoActionTest.Exec.AsyncMailboxHygieneTest do
  use JidoActionTest.Case, async: false

  alias Jido.Exec
  alias Jido.Exec.Error
  alias JidoActionTest.Fixtures.Actions.Add
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  defmodule ContinueToBlocking do
    use Jido.Action, name: "async_mailbox_continue_to_blocking"

    @impl true
    def run(params, _context), do: {:continue, params, BlockingAction}
  end

  test "await removes result and monitor messages after success" do
    handle = Exec.run_async(Add, %{value: 1})
    assert {:ok, %{value: 2}} = Exec.await(handle, 1_000)
    refute_handle_messages(handle)
  end

  test "await removes result and monitor messages after timeout" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, _worker}, 1_000
    assert {:error, %Error.AsyncTimeoutError{}} = Exec.await(handle, 0)
    refute_handle_messages(handle)
  end

  test "await accepts a queued result after a matching normal DOWN" do
    with_released_action(2, fn handle ->
      result_message = receive_result_message(handle)

      assert_receive {:DOWN, monitor_ref, :process, pid, :normal} = down, 1_000
      assert monitor_ref == handle.monitor_ref
      assert pid == handle.pid

      send(self(), down)
      send(self(), result_message)

      assert {:ok, %{value: 2}} = Exec.await(handle, 1_000)
      refute_handle_messages(handle)
    end)
  end

  test "a normal DOWN consumes an already queued result without blocking" do
    with_released_action(3, fn handle ->
      assert_receive {:DOWN, monitor_ref, :process, pid, :normal} = down, 1_000
      assert monitor_ref == handle.monitor_ref
      assert pid == handle.pid

      assert {:done, {:ok, %{value: 3}}} = Exec.handle_message(handle, down)
      refute_handle_messages(handle)
    end)
  end

  test "an unexpected normal DOWN returns one terminal execution error" do
    with_released_action(3, fn handle ->
      result_message = receive_result_message(handle)

      assert_receive {:DOWN, monitor_ref, :process, pid, :normal} = down, 1_000
      assert monitor_ref == handle.monitor_ref
      assert pid == handle.pid

      assert {:done,
              {:error,
               %Error.AsyncExecutionError{
                 message: "Asynchronous execution finished without a result",
                 details: %{operation: :handle_message}
               }}} = Exec.handle_message(handle, down)

      assert :ignore = Exec.handle_message(handle, result_message)
    end)
  end

  test "an abnormal DOWN returns one terminal execution error" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = monitor_worker(worker)

    Process.exit(handle.pid, :kill)

    assert_receive {:DOWN, monitor_ref, :process, pid, :killed} = down, 1_000
    assert monitor_ref == handle.monitor_ref
    assert pid == handle.pid

    assert {:done,
            {:error,
             %Error.AsyncExecutionError{
               details: %{operation: :handle_message, reason: :killed}
             }}} = Exec.handle_message(handle, down)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    refute_handle_messages(handle)
  end

  test "result cleanup removes its monitor messages but preserves a user monitor" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    user_monitor = Process.monitor(handle.pid)

    send(worker, :finish)
    result_message = receive_result_message(handle)

    assert_receive {:DOWN, handle_monitor, :process, pid, :normal} = handle_down, 1_000
    assert handle_monitor == handle.monitor_ref
    assert pid == handle.pid
    assert_receive {:DOWN, ^user_monitor, :process, ^pid, :normal} = user_down, 1_000

    send(self(), handle_down)
    send(self(), user_down)

    assert {:done, {:ok, %{value: 1}}} = Exec.handle_message(handle, result_message)
    assert_receive ^user_down, 1_000
    refute_received ^handle_down
  end

  test "duplicate results and stale DOWN messages are ignored" do
    with_released_action(3, fn handle ->
      result_message = receive_result_message(handle)

      assert_receive {:DOWN, monitor_ref, :process, pid, :normal} = down, 1_000
      assert monitor_ref == handle.monitor_ref
      assert pid == handle.pid

      assert {:done, {:ok, %{value: 3}}} = Exec.handle_message(handle, result_message)
      assert :ignore = Exec.handle_message(handle, result_message)
      assert :ignore = Exec.handle_message(handle, down)
    end)
  end

  test "cancel consumes the handle and repeated cancellation leaves no mailbox residue" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = monitor_worker(worker)

    assert :ok = Exec.cancel(handle)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

    assert {:error, %Error.InvalidHandleError{details: %{operation: :await}}} =
             Exec.await(handle, 0)

    assert :ok = Exec.cancel(handle)
    refute_handle_messages(handle)
  end

  test "cancellation can race with a completed result without leaving residue" do
    handle = Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
    assert_receive {:blocking_flow_node_started, worker}, 1_000

    send(worker, :finish)
    assert :ok = Exec.cancel(handle)

    assert {:error, %Error.InvalidHandleError{details: %{operation: :await}}} =
             Exec.await(handle, 0)

    refute_handle_messages(handle)
  end

  test "cancellation stops work in an active continuation" do
    handle =
      Exec.run_async(ContinueToBlocking, %{value: 1}, %{test_pid: self()}, max_continuations: 1)

    assert_receive {:blocking_flow_node_started, worker}, 1_000
    worker_monitor = monitor_worker(worker)

    assert :ok = Exec.cancel(handle)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    refute_handle_messages(handle)
  end

  defp monitor_worker(worker) do
    monitor = Process.monitor(worker)
    # Monitor requests are asynchronous. Confirm installation before another
    # process kills the worker so the DOWN reason must be :killed, not :noproc.
    assert {:monitored_by, monitors} = Process.info(worker, :monitored_by)
    assert self() in monitors
    monitor
  end

  defp with_released_action(value, fun) do
    handle = Exec.run_async(BlockingAction, %{value: value}, %{test_pid: self()})

    try do
      assert_receive {:blocking_flow_node_started, worker}, 1_000
      # The handle monitor is installed before the worker can finish.
      send(worker, :finish)
      fun.(handle)
    after
      Exec.cancel(handle)
    end
  end

  defp receive_result_message(handle) do
    monitor_ref = handle.monitor_ref
    pid = handle.pid

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        flunk("received DOWN before result: #{inspect(reason)}")

      message ->
        message
    after
      1_000 -> flunk("expected an asynchronous execution result message")
    end
  end

  defp refute_handle_messages(handle) do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:jido_exec_async_result, ref, pid, _result} ->
               ref == handle.ref and pid == handle.pid

             {:DOWN, monitor_ref, :process, pid, _reason} ->
               monitor_ref == handle.monitor_ref and pid == handle.pid

             _message ->
               false
           end)
  end
end
