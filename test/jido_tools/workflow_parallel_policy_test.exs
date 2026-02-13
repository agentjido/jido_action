defmodule JidoTest.Tools.WorkflowParallelPolicyTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error

  defmodule PassAction do
    use Jido.Action,
      name: "workflow_parallel_policy_pass",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{pass: true}}
  end

  defmodule FailAction do
    use Jido.Action,
      name: "workflow_parallel_policy_fail",
      schema: []

    @impl true
    def run(_params, _context), do: {:error, "parallel failure"}
  end

  defmodule SlowAction do
    use Jido.Action,
      name: "workflow_parallel_policy_slow",
      schema: [
        delay: [type: :non_neg_integer, default: 100]
      ]

    @impl true
    def run(%{delay: delay}, _context) do
      Process.sleep(delay)
      {:ok, %{slow: true}}
    end
  end

  defmodule CompatFailureWorkflow do
    use Jido.Tools.Workflow,
      name: "workflow_parallel_compat_failure",
      schema: [],
      workflow: [
        {:parallel, [name: "parallel"],
         [
           {:step, [name: "ok_step"], [{PassAction, []}]},
           {:step, [name: "fail_step"], [{FailAction, []}]}
         ]}
      ]
  end

  defmodule StrictFailureWorkflow do
    use Jido.Tools.Workflow,
      name: "workflow_parallel_strict_failure",
      schema: [],
      workflow: [
        {:parallel, [name: "parallel", fail_on_error: true],
         [
           {:step, [name: "ok_step"], [{PassAction, []}]},
           {:step, [name: "fail_step"], [{FailAction, []}]}
         ]}
      ]
  end

  defmodule CompatTimeoutWorkflow do
    use Jido.Tools.Workflow,
      name: "workflow_parallel_compat_timeout",
      schema: [],
      workflow: [
        {:parallel, [name: "parallel", timeout_ms: 20],
         [
           {:step, [name: "slow_step"], [{SlowAction, [delay: 100]}]},
           {:step, [name: "ok_step"], [{PassAction, []}]}
         ]}
      ]
  end

  defmodule StrictTimeoutWorkflow do
    use Jido.Tools.Workflow,
      name: "workflow_parallel_strict_timeout",
      schema: [],
      workflow: [
        {:parallel, [name: "parallel", timeout_ms: 20, fail_on_error: true],
         [
           {:step, [name: "slow_step"], [{SlowAction, [delay: 100]}]},
           {:step, [name: "ok_step"], [{PassAction, []}]}
         ]}
      ]
  end

  describe "parallel step policy" do
    test "preserves compatibility by default and aggregates errors in results" do
      assert {:ok, result} = CompatFailureWorkflow.run(%{}, %{})
      assert is_list(result.parallel_results)
      assert length(result.parallel_results) == 2
      assert Enum.any?(result.parallel_results, &match?(%{error: _}, &1))
      assert Enum.any?(result.parallel_results, &match?(%{pass: true}, &1))
    end

    test "fails fast when fail_on_error is enabled" do
      assert {:error, %Error.ExecutionFailureError{} = error} =
               StrictFailureWorkflow.run(%{}, %{})

      assert Exception.message(error) =~ "Parallel workflow step failed"
      assert is_exception(error.details[:reason])
    end

    test "returns timeout errors in results when compatibility mode is used" do
      assert {:ok, result} = CompatTimeoutWorkflow.run(%{}, %{})
      assert Enum.any?(result.parallel_results, &match?(%{error: %Error.TimeoutError{}}, &1))
    end

    test "fails the step on timeout when strict mode is enabled" do
      assert {:error, %Error.ExecutionFailureError{} = error} =
               StrictTimeoutWorkflow.run(%{}, %{})

      assert Exception.message(error) =~ "Parallel workflow step failed"
      assert %Error.TimeoutError{} = error.details[:reason]
    end
  end
end
