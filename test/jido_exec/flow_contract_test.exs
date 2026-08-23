defmodule Jido.Exec.FlowContractTest do
  use JidoTest.ActionCase, async: true

  @moduletag capture_log: true

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Node, Ref}
  alias Jido.Instruction

  alias JidoTest.ExecFixtures.{
    CountedValidationFlow,
    EnvelopeFlow,
    ImproperListOutputAction,
    ListOutputAction,
    MathFlow,
    ScalarResultFlow,
    ScalarTransformedInputFlow,
    ScalarTransformedOutputFlow,
    ShortListOutputAction,
    Transforms
  }

  alias JidoTest.FlowFixtures

  alias JidoTest.TestActions.{
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

  def fail_flow_transform(_value, mode, _opts) do
    case mode do
      :raise -> raise "flow schema boom"
      :throw -> throw(:flow_schema_boom)
    end
  end

  test "validates marked Flow modules exactly once in every execution path" do
    module = CountedValidationFlow

    for {path, run} <- flow_execution_paths(module, value: 3) do
      reset_flow_transform_counts()

      assert {:ok, %{value: 3, input_passes: 1, output_passes: 1}} =
               run.(),
             to_string(path)

      assert Transforms.calls(:input) == 1, to_string(path)
      assert Transforms.calls(:output) == 1, to_string(path)
    end
  end

  test "rejects scalar Flow output transforms in every execution path" do
    module = ScalarTransformedOutputFlow

    for {path, run} <- flow_execution_paths(module, %{value: 3}) do
      reset_flow_transform_counts()

      assert {:error, %InvalidInputError{message: message, details: details} = error} = run.(),
             to_string(path)

      assert message == "Flow output validation must return a map", to_string(path)
      assert details.context == "Flow output", to_string(path)

      assert details.phase == if(path == :parent, do: :step_execution, else: :flow_output),
             to_string(path)

      assert details.subject == module.flow(), to_string(path)
      assert details.value == :invalid, to_string(path)
      assert Jido.Action.Error.to_map(error).retryable? == false, to_string(path)
      assert Transforms.calls(:invalid_output) == 1, to_string(path)
    end
  end

  test "rejects scalar Flow input transforms in every execution path" do
    module = ScalarTransformedInputFlow

    for {path, run} <- flow_execution_paths(module, %{value: 3}) do
      reset_flow_transform_counts()

      assert {:error, %InvalidInputError{message: message, details: details} = error} = run.(),
             to_string(path)

      assert message == "Flow input validation must return a map", to_string(path)
      assert details.context == "Flow", to_string(path)

      assert details.phase == if(path == :parent, do: :step_execution, else: :flow_input),
             to_string(path)

      assert details.subject == module.flow(), to_string(path)
      assert details.value == :invalid, to_string(path)
      assert Jido.Action.Error.to_map(error).retryable? == false, to_string(path)
      assert Transforms.calls(:invalid_input) == 1, to_string(path)
    end
  end

  test "passes Flow output envelopes unchanged and bypasses the normal output schema" do
    module = EnvelopeFlow

    expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}

    for {path, run} <- flow_execution_paths(module, %{value: 3}) do
      reset_flow_transform_counts()

      assert {:ok, ^expected} = run.(), to_string(path)
      assert Transforms.calls(:envelope_output) == 0, to_string(path)
    end
  end

  test "normalizes malformed Flow output envelopes" do
    malformed = %Jido.Action.Output{kind: :stream, value: 42, meta: %{}}

    flow =
      Flow.new!(
        name: "malformed_envelope_flow",
        nodes: [
          Node.new!(
            name: :echo,
            action: EchoParamsAction,
            input: %{value: Ref.value(malformed)}
          )
        ],
        return: Ref.result(:echo, :value)
      )

    assert {:error, %InvalidInputError{message: message, details: details}} =
             Exec.run(flow, %{value: %{}}, %{})

    assert message == "invalid action output envelope"
    assert details.phase == :flow_output
  end

  test "rejects raw scalar Flow results in every execution path" do
    module = ScalarResultFlow

    for {path, run} <- flow_execution_paths(module, %{value: 3}) do
      assert {:error, %ExecutionFailureError{message: message}} = run.(), to_string(path)

      assert message == "action returned a value that requires an output envelope",
             to_string(path)
    end
  end

  test "uses zero-based result indexes in run-to-completion and step-wise execution" do
    module = ListOutputAction

    flow =
      Flow.new!(
        name: "indexed_result",
        nodes: [Node.new!(name: "output", action: module)],
        return: Ref.result("output", [:items, 0])
      )

    assert {:ok, %{value: 1}} = Exec.run(flow)
    assert {:ok, execution} = Exec.start(flow)
    assert {:ok, execution} = Exec.continue(execution)
    assert {:ok, %{value: 1}} = Exec.result(execution)
  end

  test "returns the same error for an out-of-range result index in both execution modes" do
    module = ShortListOutputAction

    flow =
      Flow.new!(
        name: "missing_index_result",
        nodes: [Node.new!(name: "output", action: module)],
        return: Ref.result("output", [:items, 99])
      )

    assert {:error, run_error} = Exec.run(flow)
    assert {:ok, execution} = Exec.start(flow)
    assert {:ok, execution} = Exec.continue(execution)
    assert {:error, step_error} = Exec.result(execution)

    assert Exception.message(run_error) ==
             "action returned a value that requires an output envelope"

    assert Exception.message(step_error) == Exception.message(run_error)
  end

  test "does not raise when a result path reaches an improper list tail" do
    module = ImproperListOutputAction

    flow =
      Flow.new!(
        name: "improper_list_result",
        nodes: [Node.new!(name: "output", action: module)],
        return: Ref.result("output", [:value, :items, 1])
      )

    assert {:error, run_error} = Exec.run(flow)
    assert {:ok, execution} = Exec.start(flow)
    assert {:ok, execution} = Exec.continue(execution)
    assert {:error, step_error} = Exec.result(execution)

    assert Exception.message(run_error) ==
             "action returned a value that requires an output envelope"

    assert Exception.message(step_error) == Exception.message(run_error)
  end

  test "executes a Flow artifact" do
    flow = FlowFixtures.math_flow!()
    assert {:ok, %{value: 8}} = Exec.run(flow, %{value: 3}, %{})
  end

  test "checks Flow action contracts before execution" do
    assert {:ok, flow} =
             Flow.new(
               name: "unchecked",
               nodes: [
                 Node.new!(
                   name: :broken,
                   action: MissingRun,
                   input: %{value: Ref.input(:value)}
                 )
               ],
               return: Ref.result(:broken)
             )

    assert {:error, %InvalidInputError{message: message, details: details}} =
             Exec.run(flow, %{value: 3}, %{})

    assert message =~ "module is not a valid Jido action"
    assert details.node == "broken"
    assert details.action == MissingRun
    assert details.reason == "missing run/2"
  end

  test "validates Flow structure before checking node action contracts" do
    flow = %Flow{
      name: "invalid_structure_first",
      description: nil,
      schema: Zoi.integer(),
      output_schema: [],
      nodes: [
        Node.new!(
          name: :broken,
          action: MissingRun,
          input: %{value: Ref.input(:value)}
        )
      ],
      return: Ref.result(:broken),
      provenance: %{}
    }

    assert {:error, %InvalidInputError{message: message, details: details}} =
             Exec.run(flow, %{value: 3}, %{})

    assert message == "schema must accept map-shaped action data"
    assert details.field == "schema"
  end

  test "normalizes nil and keyword input or context for Flow artifacts" do
    flow = FlowFixtures.math_flow!()

    assert {:ok, %{value: 8}} = Exec.run(flow, [value: 3], [])

    empty_flow =
      Flow.new!(
        name: "empty_input",
        nodes: [
          Node.new!(name: :constant, action: Add, input: %{value: Ref.value(1)})
        ],
        return: Ref.result(:constant)
      )

    assert {:ok, %{value: 2}} = Exec.run(empty_flow, nil, nil)
  end

  test "passes map input through empty Flow schemas unchanged" do
    flow =
      Flow.new!(
        name: "empty_schema_passthrough",
        schema: [],
        nodes: [
          Node.new!(
            name: :echo,
            action: EchoParamsAction,
            input: %{value: Ref.input(:value), extra: Ref.input(:extra)}
          )
        ],
        return: Ref.result(:echo)
      )

    assert {:ok, %{value: 3, extra: "kept"}} = Exec.run(flow, %{value: 3, extra: "kept"}, %{})
  end

  test "rejects invalid Flow input and context shapes" do
    flow = FlowFixtures.math_flow!()

    assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, :not_input, %{})
    assert message =~ "input must be a map or keyword list"

    assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, %{}, :not_context)
    assert message =~ "context must be a map or keyword list"

    assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, [:not_keyword], %{})
    assert message =~ "expected a map or keyword list"
  end

  test "executes a Flow module and the equivalent Flow artifact with the same result" do
    module = MathFlow

    assert module.__jido_flow__() == true
    assert Exec.run(module, %{value: 3}, %{}) == Exec.run(module.flow(), %{value: 3}, %{})
    assert {:ok, %{value: 8}} = Exec.run(module, %{value: 3}, %{})
  end

  test "converts raised action exceptions during Flow execution into execution errors" do
    flow =
      Flow.new!(
        name: "divide",
        nodes: [
          Node.new!(
            name: :divide,
            action: Divide,
            input: %{value: Ref.input(:value), amount: Ref.value(0.0)}
          )
        ],
        return: Ref.result(:divide, :value)
      )

    assert {:error, %ExecutionFailureError{message: message, details: details}} =
             Exec.run(flow, %{value: 5.0}, %{})

    assert message =~ "Cannot divide by zero"
    assert details.node == "divide"
    assert details.action == Divide
  end

  test "validates Flow output schema after extracting the declared return" do
    flow =
      Flow.new!(
        name: "context",
        output_schema: Zoi.object(%{trace_id: Zoi.integer()}),
        nodes: [
          Node.new!(name: :echo, action: ContextEcho, input: %{value: Ref.input(:value)})
        ],
        return: Ref.result(:echo)
      )

    assert {:error, %InvalidInputError{message: message, details: details}} =
             Exec.run(flow, %{value: 3}, %{trace_id: "trace"})

    assert message =~ "expected integer"
    assert details.phase == :flow_output
    assert details.context == "Flow output"
  end

  test "rejects scalar Flow output schemas during construction" do
    assert {:error, %InvalidInputError{message: message}} =
             Flow.new(
               name: "scalar_output",
               output_schema: Zoi.integer(),
               nodes: [
                 Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})
               ],
               return: Ref.result(:add_one)
             )

    assert message =~ "output_schema must accept map-shaped action data"
  end

  test "validates Flow input schema before compiling execution" do
    flow =
      Flow.new!(
        name: "input_schema",
        schema: Zoi.object(%{value: Zoi.integer()}),
        nodes: [
          Node.new!(name: :echo, action: ContextEcho, input: %{value: Ref.input(:value)})
        ],
        return: Ref.result(:echo, :value)
      )

    assert {:error, %InvalidInputError{message: message, details: details}} =
             Exec.run(flow, %{value: "bad"}, %{trace_id: "trace"})

    assert message =~ "expected integer"
    assert details.phase == :flow_input
    assert details.context == "Flow"
  end

  test "normalizes raised and thrown Flow input schema effects" do
    for mode <- [:raise, :throw] do
      flow =
        Flow.new!(
          name: "failing_input_schema",
          schema:
            Zoi.map()
            |> Zoi.transform({__MODULE__, :fail_flow_transform, [mode]}),
          nodes: [Node.new!(name: "echo", action: EchoParamsAction)],
          return: Ref.result("echo")
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow)

      assert message == "schema validation failed"
      assert details.phase == :flow_input

      assert {:error, %InvalidInputError{message: ^message}} = Exec.start(flow)
    end
  end

  test "normalizes a raised Flow output schema effect in both execution modes" do
    flow =
      Flow.new!(
        name: "failing_output_schema",
        output_schema:
          Zoi.map()
          |> Zoi.transform({__MODULE__, :fail_flow_transform, [:raise]}),
        nodes: [Node.new!(name: "echo", action: EchoParamsAction)],
        return: Ref.result("echo")
      )

    assert {:error, %InvalidInputError{message: "schema validation failed", details: details}} =
             Exec.run(flow)

    assert details.phase == :flow_output

    assert {:ok, execution} = Exec.start(flow)
    assert {:ok, _node_result, execution} = Exec.step(execution)

    assert {:error,
            %InvalidInputError{message: "schema validation failed", details: step_details}} =
             Exec.result(execution)

    assert step_details.phase == :flow_output
  end

  test "rejects scalar Flow input schemas during construction" do
    assert {:error, %InvalidInputError{message: message}} =
             Flow.new(
               name: "scalar_input_schema",
               schema: Zoi.integer(),
               nodes: [
                 Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})
               ],
               return: Ref.result(:add_one)
             )

    assert message =~ "schema must accept map-shaped action data"
  end

  test "keeps unknown flow input fields after object schema validation" do
    flow =
      Flow.new!(
        name: "object_schema_input",
        schema: Zoi.object(%{value: Zoi.integer()}),
        nodes: [
          Node.new!(
            name: :echo,
            action: EchoParamsAction,
            input: %{value: Ref.input(:value), extra: Ref.input(:extra)}
          )
        ],
        return: %{extra: Ref.result(:echo, :extra)}
      )

    assert {:ok, %{extra: "kept"}} = Exec.run(flow, %{value: 3, extra: "kept"}, %{})
  end

  test "keeps unknown flow input fields after struct schema validation" do
    flow =
      Flow.new!(
        name: "struct_schema_input",
        schema: Zoi.struct(StructInput, [value: Zoi.integer()], coerce: true),
        nodes: [
          Node.new!(
            name: :echo,
            action: EchoParamsAction,
            input: %{value: Ref.input(:value), extra: Ref.input(:extra)}
          )
        ],
        return: %{extra: Ref.result(:echo, :extra)}
      )

    assert {:ok, %{extra: "kept"}} = Exec.run(flow, %{value: 3, extra: "kept"}, %{})
  end

  test "handles map schemas without explicit field lists" do
    flow =
      Flow.new!(
        name: "dynamic_map_schema_input",
        schema: Zoi.map(Zoi.string(), Zoi.integer()),
        nodes: [
          Node.new!(
            name: :echo,
            action: EchoParamsAction,
            input: %{"value" => Ref.input("value")}
          )
        ],
        return: %{"value" => Ref.result(:echo, "value")}
      )

    assert {:ok, %{"value" => 3}} = Exec.run(flow, %{"value" => 3}, %{})
  end

  defp flow_execution_paths(module, input) do
    flow = module.flow()
    instruction = Instruction.new!(action: module, params: input)

    parent =
      Flow.new!(
        name: "parent_#{System.unique_integer([:positive])}",
        nodes: [Node.new!(name: :inner, action: module, input: Ref.input([]))],
        return: Ref.result(:inner)
      )

    [
      artifact: fn -> Exec.run(flow, input, %{}) end,
      marked_module: fn -> Exec.run(module, input, %{}) end,
      instruction: fn -> Exec.run(instruction, %{}, %{}) end,
      parent: fn -> Exec.run(parent, input, %{}) end
    ]
  end

  defp reset_flow_transform_counts do
    Transforms.reset()
  end
end
