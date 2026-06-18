defmodule JidoTest.FlowStepTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Step
  alias Jido.Instruction
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

  defmodule ManualNoSchema do
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidValidateParamsReturn do
    def run(params, _context), do: {:ok, params}
    def validate_params(_params), do: :ok
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidValidateOutputReturn do
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(_output), do: :ok
  end

  defmodule UnexpectedReturn do
    def run(_params, _context), do: :ok
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule RaisingAction do
    def run(_params, _context), do: raise("boom")
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorMapAction do
    def run(_params, _context), do: {:error, %{message: "mapped failure", code: :mapped}}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingRun do
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingValidateOutput do
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
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

  test "step hashes are structural without instruction ids" do
    left = Step.new(Add, %{amount: 2}, name: :add)
    right = Step.new(Add, %{amount: 2}, name: :add)

    assert left.hash == right.hash
    refute Map.has_key?(left.instruction, :id)
    refute Map.has_key?(right.instruction, :id)
  end

  test "builds from an instruction and merges params and context" do
    instruction =
      Instruction.new!(
        action: Add,
        params: %{amount: 1},
        context: %{trace_id: "base"}
      )

    step =
      Step.new(instruction, %{amount: 3},
        name: "add",
        context: %{tenant_id: "tenant"}
      )

    assert step.action == Add
    assert step.params == %{amount: 3}
    assert step.context == %{trace_id: "base", tenant_id: "tenant"}
  end

  test "rejects invalid constructor inputs" do
    assert_raise ArgumentError, ~r/unknown flow step options/, fn ->
      Step.new(Add, %{}, name: :add, retry: true)
    end

    assert_raise ArgumentError, ~r/expected params to be a map or keyword list/, fn ->
      Step.new(Add, 123, name: :add)
    end

    assert_raise ArgumentError, ~r/expected context to be a map or keyword list/, fn ->
      Step.new(Add, %{}, name: :add, context: 123)
    end

    assert_raise ArgumentError, ~r/expected a map or keyword list/, fn ->
      Step.new(Add, [:not, :keyword], name: :add)
    end

    assert_raise ArgumentError, ~r/expected an action module or %Jido.Instruction{}/, fn ->
      Step.new(nil, %{})
    end
  end

  test "validates action module callback contracts" do
    assert {:error, missing_run} = Step.validate_action(MissingRun)
    assert missing_run.details.reason == "missing run/2"

    assert {:error, missing_output} = Step.validate_action(MissingValidateOutput)
    assert missing_output.details.reason == "missing validate_output/1"

    assert {:error, unloaded} = Step.validate_action(Module.concat(__MODULE__, MissingModule))
    assert unloaded.message == "action module could not be loaded"

    assert {:error, invalid} = Step.validate_action("not a module")
    assert invalid.message =~ "expected an action module"
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

  test "marks invalid action callback returns as failed runnables" do
    params_step = Step.new(InvalidValidateParamsReturn, %{}, name: :bad_params)
    output_step = Step.new(InvalidValidateOutputReturn, %{}, name: :bad_output)
    return_step = Step.new(UnexpectedReturn, %{}, name: :bad_return)

    assert %{status: :failed, error: params_error} = params_step |> prepare(%{}) |> execute()
    assert params_error.message == "invalid validate_params/1 return"

    assert %{status: :failed, error: output_error} = output_step |> prepare(%{}) |> execute()
    assert output_error.message == "invalid validate_output/1 return"

    assert %{status: :failed, error: return_error} = return_step |> prepare(%{}) |> execute()
    assert return_error.message == "unexpected action return shape"
  end

  test "normalizes raised actions and map-shaped errors" do
    raised = Step.new(RaisingAction, %{}, name: :raising) |> prepare(%{}) |> execute()
    mapped = Step.new(ErrorMapAction, %{}, name: :mapped) |> prepare(%{}) |> execute()

    assert raised.status == :failed
    assert raised.error.message == "action raised during invocation"
    assert %RuntimeError{message: "boom"} = raised.error.details.reason

    assert mapped.status == :failed
    assert mapped.error.message == "mapped failure"
    assert mapped.error.details == %{code: :mapped}
  end

  test "derives Zoi schema ports from required action keys" do
    step = Step.new(Add, %{}, name: :add)

    assert Keyword.has_key?(step.inputs, :value)
    refute Keyword.has_key?(step.inputs, :amount)
    assert Keyword.has_key?(step.outputs, :value)
  end

  test "falls back to default ports when action schemas are unavailable" do
    step = Step.new(ManualNoSchema, %{}, name: :manual)

    assert step.inputs == [input: [type: :any, doc: "Input to the action"]]
    assert step.outputs == [result: [type: :any, doc: "Action result"]]
  end

  test "exposes Runic component and transmutable protocol behavior" do
    step = Step.new(Add, %{amount: 2}, name: :add)

    assert Runic.Component.connectable?(step, step)
    assert Runic.Component.hash(step) == step.hash
    assert Runic.Component.inputs(step) == step.inputs
    assert Runic.Component.outputs(step) == step.outputs

    assert %Step{} = Code.eval_quoted(Runic.Component.source(step)) |> elem(0)

    assert Runic.Transmutable.to_component(step) == step
    assert %Workflow{} = workflow = Runic.Transmutable.to_workflow(step)
    assert %{add: ^step} = Workflow.components(workflow)
    assert Runic.Transmutable.transmute(step) == workflow
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
