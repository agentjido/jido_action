defmodule JidoActionTest.Exec.AsyncErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.Error
  alias JidoActionTest.Fixtures.Actions.Add
  alias JidoActionTest.Fixtures.Execution.BlockingAction

  test "encodes the PID error returned by cancel" do
    assert {:error, %Error.InvalidHandleError{} = error} = Jido.Exec.cancel(self())

    decoded = error |> JSON.encode!() |> JSON.decode!()

    assert decoded["type"] == "async_invalid_handle"
    assert decoded["message"] == error.message
    assert decoded["details"]["pid"] == inspect(self())
    assert error.details.pid == self()
  end

  test "encodes nested invalid values from each public handle operation" do
    ref = make_ref()
    invalid = %{nested: [self(), {ref, %{exception: RuntimeError.exception("failed")}}]}

    for result <- [
          Jido.Exec.await(invalid),
          Jido.Exec.cancel(invalid),
          Jido.Exec.handle_message(invalid, :unrelated)
        ] do
      assert {:error, %Error.InvalidHandleError{} = error} = result
      assert error.details.value === invalid

      assert Error.to_map(error).details.value == %{
               nested: [inspect(self()), [inspect(ref), %{exception: "#Struct<RuntimeError>"}]]
             }

      assert_external_map(error)
    end
  end

  test "encodes PID and reference details from a consumed await handle" do
    handle = Jido.Exec.run_async(Add, %{value: 2})
    assert {:ok, %{value: 3}} = Jido.Exec.await(handle, 1_000)
    assert {:error, %Error.InvalidHandleError{} = error} = Jido.Exec.await(handle)

    assert error.details.pid == handle.pid
    assert error.details.ref == handle.ref
    assert Error.to_map(error).details.pid == inspect(handle.pid)
    assert Error.to_map(error).details.ref == inspect(handle.ref)
    assert_external_map(error)
  end

  test "encodes an actual await timeout and a stopped execution error" do
    for mode <- [:timeout, :exit] do
      handle = Jido.Exec.run_async(BlockingAction, %{value: 1}, %{test_pid: self()})
      assert_receive {:blocking_flow_node_started, worker}, 1_000
      worker_monitor = Process.monitor(worker)
      handle_monitor = Process.monitor(handle.pid)

      error =
        case mode do
          :timeout ->
            assert {:error, %Error.AsyncTimeoutError{} = error} = Jido.Exec.await(handle, 0)
            error

          :exit ->
            Process.exit(handle.pid, :kill)
            assert_receive {:DOWN, ^handle_monitor, :process, _, :killed}, 1_000
            assert {:error, %Error.AsyncExecutionError{} = error} = Jido.Exec.await(handle)
            assert error.details.pid == handle.pid
            assert Error.to_map(error).details.pid == inspect(handle.pid)
            error
        end

      assert_external_map(error)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
      Process.demonitor(handle_monitor, [:flush])
      refute Process.alive?(handle.pid)
      refute_received {:jido_exec_async_result, _, _, _}
      refute_received {:DOWN, _, :process, _, _}
    end
  end

  test "constructs and maps target-neutral async errors" do
    invalid = Error.invalid_handle_error("invalid", operation: :await)
    timeout = Error.timeout_error("late", timeout: 25, operation: :await)
    execution = Error.execution_error("failed", reason: :killed)
    cancelled = Error.cancelled_error("cancelled", operation: :cancel)

    assert Error.to_map(invalid) == %{
             type: :async_invalid_handle,
             message: "invalid",
             details: %{operation: :await},
             retryable?: false
           }

    assert Error.to_map(timeout) == %{
             type: :async_timeout,
             message: "late",
             details: %{operation: :await, timeout: 25},
             retryable?: false
           }

    assert Error.to_map(execution).type == :async_execution_error
    assert Error.to_map(cancelled).type == :async_cancelled
    assert Error.owned?(invalid)
    refute Error.owned?(RuntimeError.exception("other"))
  end

  test "encodes async errors through the stable map" do
    error = Error.timeout_error("late", timeout: 25)
    encoded = JSON.encode!(error)

    assert encoded =~ ~s("type":"async_timeout")
    assert encoded =~ ~s("timeout":25)
  end

  test "supports default constructors and each JSON encoder" do
    errors = [
      Error.invalid_handle_error("invalid"),
      Error.timeout_error("late"),
      Error.execution_error("failed"),
      Error.cancelled_error()
    ]

    assert Enum.all?(errors, &Error.owned?/1)

    for error <- errors do
      assert is_binary(JSON.encode!(error))
      assert Error.to_map(error).details == %{}
    end

    assert Error.execution_error("failed", :invalid).details == %{}
  end

  defp assert_external_map(error) do
    mapped = Error.to_map(error)
    decoded = error |> JSON.encode!() |> JSON.decode!()

    assert decoded == mapped |> JSON.encode!() |> JSON.decode!()
    assert decoded["type"] == Atom.to_string(mapped.type)
    assert decoded["message"] == error.message
  end
end
