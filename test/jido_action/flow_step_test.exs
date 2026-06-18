defmodule JidoTest.FlowStepTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Step
  alias Runic.Workflow
  alias Runic.Workflow.PolicyDriver
  alias Runic.Workflow.SchedulerPolicy

  defmodule Add do
    use Jido.Action,
      name: "flow_step_add",
      schema:
        Zoi.object(%{
          value: Zoi.integer(),
          amount: Zoi.integer() |> Zoi.default(1)
        }),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
  end

  defmodule ContextEcho do
    use Jido.Action,
      name: "flow_step_context_echo",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema:
        Zoi.object(%{
          value: Zoi.integer(),
          static: Zoi.boolean() |> Zoi.optional(),
          runtime: Zoi.boolean() |> Zoi.optional()
        })

    def run(%{value: value}, context) do
      {:ok,
       %{
         value: value,
         static: Map.get(context, :static),
         runtime: Map.get(context, :runtime)
       }}
    end
  end

  defmodule WithDirective do
    use Jido.Action,
      name: "flow_step_with_directive",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value}, %{next: :flow}}
  end

  defmodule ErrorWithDirective do
    use Jido.Action,
      name: "flow_step_error_with_directive",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{})

    def run(_params, _context), do: {:error, :transient_error, %{next: :retry}}
  end

  defmodule InvalidOutput do
    use Jido.Action,
      name: "flow_step_invalid_output",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(_params, _context), do: {:ok, %{value: "bad"}}
  end

  test "executes a Jido action through Runic prepare and execute" do
    step = Step.new(Add, %{amount: 2}, name: :add)

    executed =
      step
      |> prepare(%{value: 3})
      |> execute()

    assert executed.status == :completed
    assert executed.result.value == %{value: 5}
  end

  test "merges static params with fact params and runtime context" do
    step = Step.new(ContextEcho, %{}, name: :echo, context: %{static: true})

    workflow =
      Workflow.new(:context)
      |> Workflow.add(step)
      |> Workflow.put_run_context(%{echo: %{runtime: true}})
      |> Workflow.plan_eagerly(%{value: 7})

    {_workflow, [runnable]} = Workflow.prepare_for_dispatch(workflow)
    executed = execute(runnable)

    assert executed.status == :completed
    assert executed.result.value == %{value: 7, static: true, runtime: true}
  end

  test "preserves successful three-tuple directives as fact metadata" do
    step = Step.new(WithDirective, %{}, name: :directive)

    executed =
      step
      |> prepare(%{value: 9})
      |> execute()

    assert executed.status == :completed
    assert executed.result.value == %{value: 9}
    assert executed.result.meta.jido_directives == %{next: :flow}
    assert executed.result.meta.jido_step == :directive
    assert executed.result.meta.jido_status == :ok
  end

  test "preserves error three-tuple directives on the failed runnable error" do
    step = Step.new(ErrorWithDirective, %{}, name: :error_directive)

    executed =
      silence_logger(fn ->
        step
        |> prepare(%{})
        |> execute()
      end)

    assert executed.status == :failed
    assert %Jido.Action.Error.ExecutionFailureError{details: details} = executed.error
    assert details.reason == :transient_error
    assert details.jido_directives == %{next: :retry}
    assert details.jido_step == :error_directive
    assert details.jido_status == :error
  end

  test "projects successful three-tuple directives into Exec result" do
    flow = Flow.single(WithDirective, %{value: 9}, name: :directive)

    assert {:ok, result} = Exec.run(flow, %{})
    assert result.results.directive == [%{value: 9}]

    assert [%{step: :directive, status: :ok, directives: %{next: :flow}, fact_hash: fact_hash}] =
             result.directives

    refute is_nil(fact_hash)
  end

  test "projects error three-tuple directives into Exec result" do
    flow = Flow.single(ErrorWithDirective, %{}, name: :error_directive)

    assert {:error, result} =
             silence_logger(fn ->
               Exec.run(flow, %{})
             end)

    assert result.directives == [
             %{step: :error_directive, status: :error, directives: %{next: :retry}}
           ]
  end

  test "marks invalid action output as a failed runnable" do
    step = Step.new(InvalidOutput, %{}, name: :invalid_output)

    executed =
      step
      |> prepare(%{})
      |> execute()

    assert executed.status == :failed
    assert %Jido.Action.Error.InvalidInputError{} = executed.error
  end

  test "derives Zoi schema ports from required action keys" do
    step = Step.new(Add, %{}, name: :add)

    assert Keyword.has_key?(step.inputs, :value)
    refute Keyword.has_key?(step.inputs, :amount)
    assert Keyword.has_key?(step.outputs, :value)
  end

  defp prepare(%Step{} = step, input) do
    workflow =
      Workflow.new(:single)
      |> Workflow.add(step)
      |> Workflow.plan_eagerly(input)

    {_workflow, [runnable]} = Workflow.prepare_for_dispatch(workflow)
    runnable
  end

  defp execute(runnable) do
    PolicyDriver.execute(runnable, %SchedulerPolicy{})
  end
end
