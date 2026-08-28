defmodule JidoActionTest.Exec.AsyncErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Exec.Error

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
end
