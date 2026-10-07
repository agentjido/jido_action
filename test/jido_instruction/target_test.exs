defmodule JidoActionTest.Instruction.TargetTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Ref, Subflow}
  alias JidoActionTest.Fixtures.MathFlow
  alias JidoActionTest.Fixtures.Actions.Add

  defmodule CallbackOnly do
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule Ambiguous do
    @behaviour Jido.Action
    @behaviour Jido.Flow

    def run(params, _context), do: {:ok, params}
    def flow, do: MathFlow.flow()
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule FlowWithoutRun do
    @behaviour Jido.Flow

    @impl true
    def flow, do: MathFlow.flow()
    @impl true
    defdelegate validate_params(params), to: MathFlow
    @impl true
    defdelegate validate_output(output), to: MathFlow
  end

  defmodule ContinueToFlow do
    use Jido.Action, name: "continue_to_flow_without_run"

    @impl true
    def run(params, _context), do: {:continue, params, FlowWithoutRun}
  end

  defmodule MissingActionRun do
    @behaviour Jido.Action
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingFlowDefinition do
    @behaviour Jido.Flow
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  test "Action and Flow behaviours own their execution callbacks" do
    assert {:run, 2} in Jido.Action.behaviour_info(:callbacks)
    assert {:validate_params, 1} in Jido.Action.behaviour_info(:callbacks)
    assert {:validate_output, 1} in Jido.Action.behaviour_info(:callbacks)

    assert {:flow, 0} in Jido.Flow.behaviour_info(:callbacks)
    assert {:validate_params, 1} in Jido.Flow.behaviour_info(:callbacks)
    assert {:validate_output, 1} in Jido.Flow.behaviour_info(:callbacks)
  end

  test "generated modules declare one target behaviour" do
    assert behaviours(Add) == [Jido.Action]
    assert behaviours(MathFlow) == [Jido.Flow]
  end

  test "resolution keeps the exact target and current kind" do
    flow = MathFlow.flow()

    for {target, kind} <- [{Add, :action}, {MathFlow, :flow}, {flow, :flow}] do
      assert {:ok, %Instruction{kind: ^kind, target: ^target}} = Instruction.resolve(target)
      assert :ok = Instruction.validate(target)
    end
  end

  test "resolution ignores a stale kind in a raw Instruction" do
    stale = %Instruction{kind: :flow, target: Add, params: %{value: 1}}

    assert {:ok, %Instruction{kind: :action, target: Add}} = Instruction.resolve(stale)
    assert Exec.run(stale) == {:ok, %{value: 2}}
  end

  test "construction checks an explicit kind against the current target" do
    assert {:ok, %Instruction{kind: :action, target: Add}} =
             Instruction.new(kind: :action, target: Add)

    assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
             Instruction.new(kind: :flow, target: Add)

    assert details == %{declared: :flow, actual: :action, reason: :target_kind_changed}
  end

  test "nested Instructions flatten with right-biased shallow merges" do
    inner =
      Instruction.new!(
        target: Add,
        params: %{value: 1, nested: %{inner: true}},
        context: %{trace: "inner"},
        metadata: %{source: :inner}
      )

    outer = %Instruction{
      target: inner,
      params: %{amount: 2, nested: %{outer: true}},
      context: %{tenant: "acme"},
      metadata: %{source: :outer}
    }

    assert {:ok, instruction} = Instruction.resolve(outer, %{amount: 3}, %{trace: "call"})
    assert instruction.target == Add
    assert instruction.kind == :action
    assert instruction.params == %{value: 1, amount: 3, nested: %{outer: true}}
    assert instruction.context == %{trace: "call", tenant: "acme"}
    assert instruction.metadata == %{source: :outer}
  end

  test "canonical Flow components reject bound Instructions" do
    action = Instruction.new!(target: Add, params: %{amount: 2})
    flow = Instruction.new!(target: MathFlow, params: %{value: 2})

    assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
             Jido.Flow.Step.new(name: "action", action: action)

    assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
             Jido.Flow.Subflow.new(name: "flow", flow: flow)
  end

  test "callbacks without a target behaviour do not classify a module" do
    assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
             Instruction.resolve(CallbackOnly)

    assert details == %{target: CallbackOnly, reason: :missing_behaviour}
  end

  test "a module cannot implement both target behaviours" do
    assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
             Instruction.resolve(Ambiguous)

    assert details == %{target: Ambiguous, reason: :ambiguous_behaviour}
  end

  test "validation checks callbacks for the resolved kind" do
    for {target, callback} <- [
          {MissingActionRun, "run/2"},
          {MissingFlowDefinition, "flow/0"}
        ] do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Instruction.validate(target)

      assert error.message == "module is not a valid Instruction target"
      assert error.details == %{target: target, reason: "missing #{callback}"}
    end
  end

  test "a Flow without run/2 executes through all public target forms" do
    input = %{value: 3}
    expected = {:ok, %{value: 8}}
    instruction = Instruction.new!(target: FlowWithoutRun, params: input)

    parent =
      Flow.new!(
        name: "flow_without_run_parent",
        components: [Subflow.new!(name: "child", flow: FlowWithoutRun, params: Ref.input([]))],
        output: Ref.result("child")
      )

    assert Exec.run(FlowWithoutRun, input) == expected
    assert Exec.run(instruction) == expected
    assert Exec.run(parent, input) == expected
    assert Exec.run(ContinueToFlow, input) == expected
    assert FlowWithoutRun |> Exec.run_async(input) |> Exec.await() == expected

    for target <- [FlowWithoutRun, instruction, parent] do
      assert {:ok, execution} = Exec.start(target, input)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == expected
    end
  end

  test "generated Flow run/2 delegates to Exec" do
    assert MathFlow.run(%{value: 3}, %{}) == Exec.run(MathFlow, %{value: 3})
    assert MathFlow.run(%{value: "bad"}, %{}) == Exec.run(MathFlow, %{value: "bad"})
  end

  defp behaviours(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
