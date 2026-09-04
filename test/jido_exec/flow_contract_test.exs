defmodule JidoActionTest.Exec.FlowContractTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error.ExecutionFailureError, as: ActionExecutionFailureError
  alias Jido.Executable
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Error.{InvalidDefinitionError, InvalidExecutionError}
  alias Jido.Flow.{Ref, Step}
  alias Jido.Instruction
  alias JidoActionTest.Fixtures.Execution, as: ExecFixtures

  alias JidoActionTest.Fixtures.{
    CountedValidationFlow,
    EnvelopeFlow,
    ImproperListOutputAction,
    InlineResultFlow,
    ListOutputAction,
    MathFlow,
    ScalarResultFlow,
    ScalarTransformedInputFlow,
    ScalarTransformedOutputFlow,
    ShortListOutputAction,
    Transforms
  }

  alias JidoActionTest.Fixtures.FlowAuthoring, as: FlowFixtures

  alias JidoActionTest.Fixtures.Actions.{
    Add,
    ContextEcho,
    Divide,
    EchoParamsAction,
    MissingRun
  }

  defmodule StructInput do
    @moduledoc false
    defstruct [:value]
  end

  defmodule InlinePatternFlow do
    use Jido.Flow, name: "inline_pattern_boundary"

    flow do
      step "match",
           %{profile: %{name: name}, active: true, test_pid: test_pid, token: token} <-
             input(:payload) do
        send(test_pid, {:inline_pattern_body, token})
        {:ok, %{name: name}}
      end

      output(result("match"))
    end
  end

  defmodule InlineContextFlow do
    use Jido.Flow, name: "inline_context_boundary"

    flow do
      step "first", [value <- input(:value), ctx <- context()] do
        value = value + 1
        ctx = Map.put(ctx, :local_only, true)
        {:ok, %{value: value, context: ctx}}
      end

      step "second",
           [value <- input(:value), prior <- result("first"), ctx <- context()] do
        {:ok, %{value: value, prior: prior, context: ctx}}
      end

      output(result("second"))
    end
  end

  defmodule InlineSchemaFlow do
    use Jido.Flow,
      name: "inline_schema_boundary",
      schema: Zoi.object(%{value: Zoi.integer() |> Zoi.default(1)}),
      output_schema: Zoi.object(%{value: Zoi.integer() |> Zoi.min(0)})

    flow do
      step "echo", value <- input(:value) do
        {:ok, %{value: value}}
      end

      output result("echo")
    end
  end

  test "inline binding failures stop before body work at the existing boundaries" do
    token = make_ref()
    payload = %{profile: %{name: "Ada"}, active: true, test_pid: self(), token: token}

    assert {:error, %Jido.Flow.Error.ExecutionFailureError{} = missing_ref} =
             Exec.run(InlinePatternFlow)

    assert missing_ref.message == "flow reference path does not exist"
    assert missing_ref.details.reason == :missing_key
    assert missing_ref.details.path == [:payload]
    refute_received {:inline_pattern_body, ^token}

    for invalid <- [put_in(payload.profile, %{}), %{payload | active: false}] do
      assert {:error, %ActionExecutionFailureError{} = mismatch} =
               Exec.run(InlinePatternFlow, %{payload: invalid})

      assert mismatch.details.exception == FunctionClauseError
      assert mismatch.details.action == InlinePatternFlow.step_action("match")
      assert mismatch.details.node == "match"
      refute_received {:inline_pattern_body, ^token}
    end

    assert {:error, %Jido.Action.Error.InvalidInputError{} = non_map} =
             Exec.run(InlinePatternFlow, %{payload: :not_a_map})

    assert non_map.details.node == "match"
    refute_received {:inline_pattern_body, ^token}

    assert Exec.run(InlinePatternFlow, %{payload: Map.put(payload, :extra, :accepted)}) ==
             {:ok, %{name: "Ada"}}

    assert_received {:inline_pattern_body, ^token}
    refute_received {:inline_pattern_body, ^token}
  end

  test "inline Steps preserve caller context and keep header bindings local" do
    context = %{trace_id: make_ref(), prefix: "Hello"}

    assert Exec.run(InlineContextFlow, %{value: 3}, context) ==
             {:ok,
              %{
                value: 3,
                prior: %{value: 4, context: Map.put(context, :local_only, true)},
                context: context
              }}
  end

  test "an extracted inline target does not recreate context bindings" do
    action = InlineContextFlow.step_action("first")
    context = %{trace_id: "inline-reuse"}

    assert {:error, %ActionExecutionFailureError{details: details}} =
             Exec.run(action, %{value: 3}, context)

    assert details.exception == FunctionClauseError
    assert details.action == action

    assert Exec.run(action, %{value: 3, ctx: context}, %{trace_id: "other"}) ==
             {:ok, %{value: 4, context: Map.put(context, :local_only, true)}}
  end

  test "an extracted inline target does not inherit Flow input validation or defaults" do
    action = InlineSchemaFlow.step_action("echo")
    assert action.schema() == []
    assert Exec.run(InlineSchemaFlow) == {:ok, %{value: 1}}

    assert {:error, %ActionExecutionFailureError{details: %{exception: FunctionClauseError}}} =
             Exec.run(action)

    assert {:error, %InvalidExecutionError{details: %{phase: :flow_input}}} =
             Exec.run(InlineSchemaFlow, %{value: "invalid"})

    assert Exec.run(action, %{value: "invalid"}) == {:ok, %{value: "invalid"}}
  end

  test "an extracted inline target does not inherit Flow output validation" do
    action = InlineSchemaFlow.step_action("echo")
    assert action.output_schema() == []
    assert Exec.run(action, %{value: -1}) == {:ok, %{value: -1}}

    assert {:error, %InvalidExecutionError{details: %{phase: :flow_output}}} =
             Exec.run(InlineSchemaFlow, %{value: -1})
  end

  test "one inline target has equal results across public execution forms" do
    input = %{mode: :map, value: 3}
    action = InlineResultFlow.step_action("result")
    expected = {:ok, %{value: 3}}

    assert Exec.run(action, input) == expected
    assert Exec.run(Instruction.new!(target: action, params: input)) == expected

    for {path, run} <- ExecFixtures.flow_execution_paths(InlineResultFlow, input) do
      assert run.() == expected, to_string(path)
    end

    for target <- [action, InlineResultFlow] do
      handle = Exec.run_async(target, input)
      assert Exec.await(handle) == expected
    end

    assert {:ok, execution} = Exec.start(InlineResultFlow, input)
    assert [runnable] = Exec.ready(execution)
    assert {:ok, %{status: :completed}, execution} = Exec.step(execution, runnable)
    assert Exec.status(execution) == :succeeded
    assert Exec.result(execution) == expected
  end

  def fail_flow_transform(_value, mode, _opts) do
    case mode do
      :raise -> raise "flow schema boom"
      :throw -> throw(:flow_schema_boom)
    end
  end

  test "validates Flow modules once in every execution path" do
    for {path, run} <- ExecFixtures.flow_execution_paths(CountedValidationFlow, %{value: 3}) do
      Transforms.reset()

      assert run.() == {:ok, %{value: 3, input_passes: 1, output_passes: 1}},
             to_string(path)

      assert Transforms.calls(:input) == 1, to_string(path)
      assert Transforms.calls(:output) == 1, to_string(path)
    end
  end

  test "rejects scalar Flow output transforms in every execution path" do
    for {path, run} <-
          ExecFixtures.flow_execution_paths(ScalarTransformedOutputFlow, %{value: 3}) do
      Transforms.reset()

      assert {:error, %InvalidExecutionError{message: message, details: details}} = run.(),
             to_string(path)

      if path == :subflow do
        assert message == "Action output validation must return a map"
        assert details.context == "Action output"
      else
        assert message == "Flow output validation must return a map"
        assert details.context == "Flow output"
        assert details.phase == :flow_output
      end

      assert Transforms.calls(:invalid_output) == 1
    end
  end

  test "rejects scalar Flow input transforms in every execution path" do
    for {path, run} <-
          ExecFixtures.flow_execution_paths(ScalarTransformedInputFlow, %{value: 3}) do
      Transforms.reset()

      assert {:error, %InvalidExecutionError{message: message, details: details}} = run.(),
             to_string(path)

      if path == :subflow do
        assert message == "Action validation must return a map"
        assert details.context == "Action"
      else
        assert message == "Flow input validation must return a map"
        assert details.context == "Flow"
        assert details.phase == :flow_input
      end

      assert Transforms.calls(:invalid_input) == 1
    end
  end

  test "passes Flow output envelopes without normal output schema validation" do
    expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}

    for {path, run} <- ExecFixtures.flow_execution_paths(EnvelopeFlow, %{value: 3}) do
      Transforms.reset()
      assert run.() == {:ok, expected}, to_string(path)
      assert Transforms.calls(:envelope_output) == 0
    end
  end

  test "rejects scalar Flow results in every execution path" do
    for {path, run} <- ExecFixtures.flow_execution_paths(ScalarResultFlow, %{value: 3}) do
      assert {:error, error} = run.(), to_string(path)

      expected =
        if path == :subflow,
          do: "Action output validation must return a map",
          else: "Flow returned a value that requires an output envelope"

      assert Exception.message(error) == expected
    end
  end

  test "uses zero-based result indexes in full and step-wise execution" do
    flow =
      Flow.new!(
        name: "indexed_result",
        components: [Step.new!(name: "output", action: ListOutputAction)],
        output: Ref.result("output", [:items, 0])
      )

    assert Exec.run(flow) == {:ok, %{value: 1}}
    assert {:ok, execution} = Exec.start(flow)
    assert {:ok, execution} = Exec.continue(execution)
    assert Exec.result(execution) == {:ok, %{value: 1}}
  end

  test "returns the same result path error in both execution modes" do
    flow =
      Flow.new!(
        name: "missing_index_result",
        components: [Step.new!(name: "output", action: ShortListOutputAction)],
        output: Ref.result("output", [:items, 99])
      )

    assert {:error, run_error} = Exec.run(flow)
    assert {:ok, execution} = Exec.start(flow)
    assert {:ok, execution} = Exec.continue(execution)
    assert {:error, step_error} = Exec.result(execution)

    assert Exception.message(run_error) == "flow reference path does not exist"
    assert run_error.details.reason == :missing_index
    assert run_error.details.node == "output"
    assert step_error.details == run_error.details
  end

  test "returns a reference error from inside a list" do
    flow =
      Flow.new!(
        name: "missing_input_in_list",
        components: [
          Step.new!(
            name: "echo",
            action: EchoParamsAction,
            params: %{values: [Ref.input(:present), Ref.input(:missing)]}
          )
        ],
        output: Ref.result("echo")
      )

    assert {:error, error} = Exec.run(flow, %{present: :available})
    assert Exception.message(error) == "flow reference path does not exist"

    assert error.details == %{
             path: [:missing],
             reason: :missing_key,
             ref_type: :input,
             resolved_path: [],
             retry: false,
             segment: :missing,
             value_type: :map
           }
  end

  test "reports a result path that reaches an improper list tail" do
    flow =
      Flow.new!(
        name: "improper_list_result",
        components: [Step.new!(name: "output", action: ImproperListOutputAction)],
        output: Ref.result("output", [:value, :items, 1])
      )

    assert {:error, error} = Exec.run(flow)
    assert error.details.reason == :missing_index
    assert error.details.segment == 1
    assert error.details.resolved_path == [:value, :items]
  end

  test "executes a Flow module and equivalent artifact" do
    flow = FlowFixtures.math_flow!()

    assert {:ok, %Executable{kind: :flow, target: MathFlow}} = Executable.resolve(MathFlow)
    assert Exec.run(MathFlow, %{value: 3}) == Exec.run(MathFlow.flow(), %{value: 3})
    assert Exec.run(flow, %{value: 3}) == {:ok, %{value: 8}}
  end

  test "checks Action contracts before execution" do
    flow =
      Flow.new!(
        name: "unchecked",
        components: [
          Step.new!(name: "broken", action: MissingRun, params: %{value: Ref.input(:value)})
        ],
        output: Ref.result("broken")
      )

    assert {:error, %InvalidDefinitionError{message: message, details: details}} =
             Exec.run(flow, %{value: 3})

    assert message =~ "module is not a valid Jido executable"
    assert details.component == "broken"
    assert details.executable == MissingRun
  end

  test "normalizes nil and keyword Flow input and context" do
    flow = FlowFixtures.math_flow!()
    assert Exec.run(flow, [value: 3], []) == {:ok, %{value: 8}}

    empty_flow =
      Flow.new!(
        name: "empty_input",
        components: [Step.new!(name: "constant", action: Add, params: %{value: 1})],
        output: Ref.result("constant")
      )

    assert Exec.run(empty_flow, nil, nil) == {:ok, %{value: 2}}
  end

  test "rejects invalid Flow input and context shapes" do
    flow = FlowFixtures.math_flow!()

    assert {:error, %InvalidExecutionError{message: message}} = Exec.run(flow, :bad, %{})
    assert message =~ "input must be a map or keyword list"

    assert {:error, %InvalidExecutionError{message: message}} = Exec.run(flow, %{}, :bad)
    assert message =~ "context must be a map or keyword list"

    assert {:error, %InvalidExecutionError{message: message}} = Exec.run(flow, [:bad], %{})
    assert message =~ "expected a map or keyword list"
  end

  test "converts raised Action exceptions during Flow execution" do
    flow =
      Flow.new!(
        name: "divide",
        components: [
          Step.new!(
            name: "divide",
            action: Divide,
            params: %{value: Ref.input(:value), amount: 0.0}
          )
        ],
        output: Ref.result("divide", :value)
      )

    assert {:error, %ActionExecutionFailureError{message: message, details: details}} =
             Exec.run(flow, %{value: 5.0})

    assert message =~ "Cannot divide by zero"
    assert details.node == "divide"
    assert details.action == Divide
  end

  test "validates Flow input and output schemas at their boundaries" do
    input_flow =
      Flow.new!(
        name: "input_schema",
        schema: Zoi.object(%{value: Zoi.integer()}),
        components: [
          Step.new!(name: "echo", action: ContextEcho, params: %{value: Ref.input(:value)})
        ],
        output: Ref.result("echo")
      )

    assert {:error, %InvalidExecutionError{details: %{phase: :flow_input}}} =
             Exec.run(input_flow, %{value: "bad"})

    output_flow = %{
      input_flow
      | name: "output_schema",
        schema: [],
        output_schema: Zoi.object(%{trace_id: Zoi.integer()})
    }

    assert {:error, %InvalidExecutionError{details: %{phase: :flow_output}}} =
             Exec.run(output_flow, %{value: 3}, %{trace_id: "trace"})
  end

  test "normalizes raised and thrown Flow schema effects" do
    for mode <- [:raise, :throw] do
      flow =
        Flow.new!(
          name: "failing_input_schema_#{mode}",
          schema: Zoi.map() |> Zoi.transform({__MODULE__, :fail_flow_transform, [mode]}),
          components: [Step.new!(name: "echo", action: EchoParamsAction)],
          output: Ref.result("echo")
        )

      assert {:error, %InvalidExecutionError{message: "schema validation failed"}} =
               Exec.run(flow)

      assert {:error, %InvalidExecutionError{message: "schema validation failed"}} =
               Exec.start(flow)
    end

    flow =
      Flow.new!(
        name: "failing_output_schema",
        output_schema: Zoi.map() |> Zoi.transform({__MODULE__, :fail_flow_transform, [:raise]}),
        components: [Step.new!(name: "echo", action: EchoParamsAction)],
        output: Ref.result("echo")
      )

    assert {:error, %InvalidExecutionError{details: %{phase: :flow_output}}} = Exec.run(flow)
  end

  test "keeps unknown input fields after object and struct validation" do
    for schema <- [
          Zoi.object(%{value: Zoi.integer()}),
          Zoi.struct(StructInput, [value: Zoi.integer()], coerce: true)
        ] do
      flow =
        Flow.new!(
          name: "unknown_fields_#{System.unique_integer([:positive])}",
          schema: schema,
          components: [
            Step.new!(
              name: "echo",
              action: EchoParamsAction,
              params: %{value: Ref.input(:value), extra: Ref.input(:extra)}
            )
          ],
          output: %{extra: Ref.result("echo", :extra)}
        )

      assert Exec.run(flow, %{value: 3, extra: "kept"}) == {:ok, %{extra: "kept"}}
    end
  end
end
