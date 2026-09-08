defmodule Jido.ExecRetryPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec
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

    test "a :retryable? predicate can reject an error the default treats as retryable" do
      error = {:error, Error.execution_error("temporary failure")}

      refute Retry.should_retry?(error, 0, 3, retryable?: fn _ -> false end)
    end

    test "a :retryable? predicate can accept an error the default rejects" do
      error = {:error, Error.validation_error("invalid input")}

      assert Retry.should_retry?(error, 0, 3, retryable?: fn _ -> true end)
    end

    test "a :retryable? predicate receives the extracted error target" do
      error = {:error, Error.execution_error("temporary failure")}

      assert Retry.should_retry?(error, 0, 3,
               retryable?: fn target -> match?(%Error.ExecutionFailureError{}, target) end
             )
    end

    test "without :retryable? the default Error.retryable?/1 heuristic still applies" do
      retryable = {:error, Error.execution_error("temporary failure")}
      not_retryable = {:error, Error.validation_error("invalid input")}

      assert Retry.should_retry?(retryable, 0, 3, [])
      refute Retry.should_retry?(not_retryable, 0, 3, [])
    end

    test "a non-function :retryable? value is ignored and falls back to the default" do
      retryable = {:error, Error.execution_error("temporary failure")}
      not_retryable = {:error, Error.validation_error("invalid input")}

      assert Retry.should_retry?(retryable, 0, 3, retryable?: :not_a_function)
      refute Retry.should_retry?(not_retryable, 0, 3, retryable?: :not_a_function)
    end

    test "retry_count >= max_retries short-circuits even with a permissive :retryable?" do
      error = {:error, Error.validation_error("invalid input")}

      refute Retry.should_retry?(error, 3, 3, retryable?: fn _ -> true end)
    end
  end

  describe "extract_retry_opts/1" do
    test "includes :retryable? as nil when absent" do
      assert Retry.extract_retry_opts([])[:retryable?] == nil
    end

    test "passes through a provided :retryable? function unchanged" do
      predicate = fn _ -> true end

      assert Retry.extract_retry_opts(retryable?: predicate)[:retryable?] == predicate
    end
  end

  describe "Jido.Exec.run/4 with :retryable?" do
    defmodule DenyingAction do
      @moduledoc false
      use Jido.Action, name: "retry_policy_denying_action"

      def run(_params, context) do
        :ets.update_counter(context.attempts_table, :attempts, {2, 1})
        {:error, Error.execution_error("access denied")}
      end
    end

    defmodule OverriddenRetryableAction do
      @moduledoc false
      use Jido.Action, name: "retry_policy_overridden_retryable_action"

      def run(_params, context) do
        :ets.update_counter(context.attempts_table, :attempts, {2, 1})
        {:error, Error.validation_error("rejected input")}
      end
    end

    setup do
      table = :ets.new(:retry_policy_attempts, [:set, :public])
      :ets.insert(table, {:attempts, 0})

      {:ok, table: table}
    end

    test "a predicate that rejects a normally-retryable error runs the action exactly once",
         %{table: table} do
      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{}} =
                 Exec.run(DenyingAction, %{}, %{attempts_table: table},
                   max_retries: 2,
                   backoff: 1,
                   retryable?: fn _ -> false end
                 )
      end)

      assert :ets.lookup(table, :attempts) == [{:attempts, 1}]
    end

    test "a predicate that accepts a normally-non-retryable error causes it to be retried",
         %{table: table} do
      capture_log(fn ->
        assert {:error, %Error.InvalidInputError{}} =
                 Exec.run(OverriddenRetryableAction, %{}, %{attempts_table: table},
                   max_retries: 2,
                   backoff: 1,
                   retryable?: fn _ -> true end
                 )
      end)

      assert :ets.lookup(table, :attempts) == [{:attempts, 3}]
    end

    test "without :retryable? the default behaviour is unchanged (no retry on validation errors)",
         %{table: table} do
      capture_log(fn ->
        Exec.run(OverriddenRetryableAction, %{}, %{attempts_table: table},
          max_retries: 2,
          backoff: 1
        )
      end)

      assert :ets.lookup(table, :attempts) == [{:attempts, 1}]
    end

    test "a non-function :retryable? value is ignored, falling back to the default", %{
      table: table
    } do
      capture_log(fn ->
        Exec.run(OverriddenRetryableAction, %{}, %{attempts_table: table},
          max_retries: 2,
          backoff: 1,
          retryable?: :not_a_function
        )
      end)

      assert :ets.lookup(table, :attempts) == [{:attempts, 1}]
    end
  end
end
