defmodule Jido.ExecRetryPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Exec.Retry

  describe "should_retry?/4" do
    test "does not retry validation errors" do
      error = {:error, Error.validation_error("invalid input")}

      refute Retry.should_retry?(error, 0, 3, [])
    end

    test "does not retry configuration errors" do
      error = {:error, Error.config_error("bad config")}

      refute Retry.should_retry?(error, 0, 3, [])
    end

    test "retries execution errors by default" do
      error = {:error, Error.execution_error("temporary failure")}

      assert Retry.should_retry?(error, 0, 3, [])
    end

    test "does not retry when execution error details include retry: false" do
      error = {:error, Error.execution_error("permanent failure", %{retry: false})}

      refute Retry.should_retry?(error, 0, 3, [])
    end

    test "does not retry when nested reason includes retry: false" do
      error =
        {:error,
         Error.execution_error("wrapped failure", %{
           reason: %{retry: false, source: :upstream}
         })}

      refute Retry.should_retry?(error, 0, 3, [])
    end

    test "stops retrying when retry_count reaches max_retries" do
      error = {:error, Error.execution_error("retry until limit")}

      refute Retry.should_retry?(error, 2, 2, [])
    end
  end
end
