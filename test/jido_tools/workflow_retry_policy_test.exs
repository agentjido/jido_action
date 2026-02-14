defmodule JidoTest.Tools.WorkflowRetryPolicyTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Tools.Workflow

  @counter __MODULE__.Counter

  defmodule CounterFailAction do
    use Jido.Action,
      name: "workflow_retry_counter_fail",
      schema: []

    @impl true
    def run(_params, _context) do
      Agent.update(JidoTest.Tools.WorkflowRetryPolicyTest.Counter, &(&1 + 1))
      {:error, "retry me"}
    end
  end

  defmodule DefaultRetryWorkflow do
    use Workflow,
      name: "workflow_retry_default_policy",
      schema: [],
      workflow: [
        {:step, [name: "count_fail"], [{CounterFailAction, []}]}
      ]
  end

  defmodule OverrideRetryWorkflow do
    use Workflow,
      name: "workflow_retry_override_policy",
      schema: [],
      workflow: [
        {:step, [name: "count_fail"],
         [{CounterFailAction, %{}, %{}, [max_retries: 1, backoff: 0]}]}
      ]
  end

  setup do
    {:ok, pid} = Agent.start_link(fn -> 0 end, name: @counter)

    on_exit(fn ->
      if Process.alive?(pid), do: Agent.stop(pid)
    end)

    original_max_retries = Application.get_env(:jido_action, :default_max_retries)

    on_exit(fn ->
      if is_nil(original_max_retries) do
        Application.delete_env(:jido_action, :default_max_retries)
      else
        Application.put_env(:jido_action, :default_max_retries, original_max_retries)
      end
    end)

    :ok
  end

  test "workflow internal steps default to max_retries: 0" do
    Application.put_env(:jido_action, :default_max_retries, 3)

    assert {:error, _} = DefaultRetryWorkflow.run(%{}, %{})
    assert Agent.get(@counter, & &1) == 1
  end

  test "workflow preserves explicit max_retries override on instruction opts" do
    Application.put_env(:jido_action, :default_max_retries, 3)

    assert {:error, _} = OverrideRetryWorkflow.run(%{}, %{})
    assert Agent.get(@counter, & &1) == 2
  end
end
