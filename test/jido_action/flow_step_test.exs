defmodule JidoTest.FlowStepTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Step
  alias Jido.Instruction

  alias JidoTest.TestActions.{
    Add,
    ContextEcho,
    EmptyDirective,
    ErrorExceptionAction,
    ErrorExceptionWithDirective,
    ErrorMapAction,
    ErrorTupleAction,
    ErrorWithDirective,
    ErrorWithEmptyDirective,
    InvalidFlowOutput,
    InvalidOutputWithDirective,
    InvalidValidateOutputReturn,
    InvalidValidateParamsReturn,
    ManualNoSchema,
    MissingRun,
    OptionalInput,
    RaisingAction,
    ScalarSchema,
    UnexpectedReturn,
    ValidateParamsError,
    WithDirective
  }

  alias Runic.Workflow
  alias Runic.Workflow.PolicyDriver
  alias Runic.Workflow.SchedulerPolicy

  test "builds default names and normalizes optional maps" do
    derived = Step.new(Add, [amount: 2], context: [trace_id: "trace"])
    nil_params = Step.new(Add, nil, name: :add)

    assert derived.name == :add
    assert derived.params == %{amount: 2}
    assert derived.context == %{trace_id: "trace"}
    assert nil_params.params == %{}
  end

  test "rejects invalid step names through struct validation" do
    assert_raise ArgumentError, ~r/invalid flow step/, fn ->
      Step.new(Add, %{}, name: "")
    end
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

  test "invokes a Jido action through the Runic invokable protocol" do
    step = Step.new(Add, %{amount: 2}, name: :add)

    workflow =
      Workflow.new(:invoke)
      |> Workflow.add(step)
      |> Workflow.plan_eagerly(%{value: 3})

    [fact] = Workflow.facts(workflow)

    assert %Workflow{} = workflow = Runic.Workflow.Invokable.invoke(step, workflow, fact)
    assert Workflow.raw_productions(workflow, :add) == [%{value: 5}]
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

    assert_raise ArgumentError, ~r/flow step options must be a keyword list/, fn ->
      apply(Step, :new, [Add, %{}, :invalid])
    end

    assert_raise ArgumentError, ~r/flow step options must be a keyword list/, fn ->
      Step.new(Add, %{}, [:not, :keyword])
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

    assert_raise ArgumentError, ~r/not a valid Jido action/, fn ->
      Step.new(MissingRun, %{}, name: :missing_run)
    end
  end

  test "marks parameter validation errors as failed runnables" do
    step = Step.new(ValidateParamsError, %{}, name: :bad_params)

    assert %{status: :failed, error: error} = step |> prepare(%{}) |> execute()
    assert error.message == "bad params"
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
    flow = Flow.from_action(WithDirective, %{value: 9}, name: :directive)

    assert {:ok, result} = Exec.run(flow, %{})
    assert result.results.directive == [%{value: 9}]

    assert [%{step: :directive, status: :ok, directives: %{next: :flow}, fact_hash: fact_hash}] =
             result.directives

    refute is_nil(fact_hash)
  end

  test "projects error three-tuple directives into Exec result" do
    flow = Flow.from_action(ErrorWithDirective, %{}, name: :error_directive)

    assert {:error, result} =
             silence_logger(fn ->
               Exec.run(flow, %{})
             end)

    assert result.directives == [
             %{step: :error_directive, status: :error, directives: %{next: :retry}}
           ]
  end

  test "marks invalid action output as a failed runnable" do
    step = Step.new(InvalidFlowOutput, %{}, name: :invalid_output)

    executed =
      step
      |> prepare(%{})
      |> execute()

    assert executed.status == :failed
    assert %Jido.Action.Error.InvalidInputError{} = executed.error
  end

  test "preserves directives when three-tuple output validation fails" do
    step = Step.new(InvalidOutputWithDirective, %{}, name: :invalid_output_directive)

    executed =
      step
      |> prepare(%{})
      |> execute()

    assert executed.status == :failed
    assert executed.error.details.jido_directives == %{next: :repair}
    assert executed.error.details.jido_step == :invalid_output_directive
    assert %Jido.Action.Error.InvalidInputError{} = executed.error.details.reason
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

  test "normalizes exception and tuple error returns" do
    direct_exception = Step.new(ErrorExceptionAction, %{}, name: :direct_exception)
    tuple_reason = Step.new(ErrorTupleAction, %{}, name: :tuple_reason)

    assert %{status: :failed, error: %RuntimeError{message: "direct failure"}} =
             direct_exception |> prepare(%{}) |> execute()

    assert %{status: :failed, error: tuple_error} = tuple_reason |> prepare(%{}) |> execute()
    assert tuple_error.message == "action invocation failed"
    assert tuple_error.details.reason == {:bad, :shape}
  end

  test "normalizes directive-bearing exception and empty directive returns" do
    exception_directive = Step.new(ErrorExceptionWithDirective, %{}, name: :exception_directive)
    empty_error = Step.new(ErrorWithEmptyDirective, %{}, name: :empty_error)
    empty_success = Step.new(EmptyDirective, %{value: 1}, name: :empty_success)

    assert %{status: :failed, error: exception_error} =
             exception_directive |> prepare(%{}) |> execute()

    assert exception_error.message == "directive failure"
    assert exception_error.details.jido_directives == %{next: :retry}
    assert exception_error.details.jido_step == :exception_directive

    assert %{status: :failed, error: empty_error} = empty_error |> prepare(%{}) |> execute()
    assert empty_error.message == "empty_directive"
    refute Map.has_key?(empty_error.details, :jido_directives)

    assert %{status: :completed, result: result} = empty_success |> prepare(%{}) |> execute()
    assert result.meta == %{}
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

  test "derives ports from optional and scalar schemas" do
    optional = Step.new(OptionalInput, %{}, name: :optional)
    scalar = Step.new(ScalarSchema, %{}, name: :scalar)

    assert Keyword.has_key?(optional.inputs, :value)
    refute Keyword.has_key?(optional.inputs, :label)
    assert scalar.inputs == [input: [type: :any, doc: "Input to the action"]]
    assert scalar.outputs == [result: [type: :any, doc: "Action result"]]
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
