defmodule Jido.ExecTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError, InvalidInputError}
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Builder, Choice, Condition, Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Instruction
  alias JidoTest.FlowFixtures

  alias JidoTest.TestActions.{
    Add,
    AtomValidationAction,
    AtomErrorAction,
    ContextEcho,
    DelayedEchoAction,
    DelayedErrorAction,
    Divide,
    EchoParamsAction,
    ErrorAction,
    ErrorWithExtrasAction,
    ExceptionErrorAction,
    ExtrasAction,
    InvalidValidatedOutputAction,
    InvalidValidatedParamsAction,
    MissingRun,
    NoneExtrasAction,
    OutputEnvelopeAction,
    RawOutputAction,
    RawOutputWithExtrasAction,
    InvalidValidationResultAction,
    RaisingOutputValidationAction,
    RaisingValidationAction,
    ThrowingAction,
    TupleErrorAction,
    UnsupportedResult
  }

  defmodule StructInput do
    @moduledoc false
    defstruct [:value]
  end

  def count_flow_transform(value, kind, _opts) do
    counter_key = {__MODULE__, kind}
    Process.put(counter_key, Process.get(counter_key, 0) + 1)

    transformed =
      case kind do
        :input -> Map.update(value, :input_passes, 1, &(&1 + 1))
        :invalid_input -> :invalid
        :output -> Map.update(value, :output_passes, 1, &(&1 + 1))
        :envelope_output -> value
        :invalid_output -> :invalid
      end

    {:ok, transformed}
  end

  def fail_flow_transform(_value, mode, _opts) do
    case mode do
      :raise -> raise "flow schema boom"
      :throw -> throw(:flow_schema_boom)
    end
  end

  describe "run/3 with action modules" do
    test "executes a leaf action with input and context validation" do
      assert {:ok, %{value: 6}} = Exec.run(Add, %{value: 5}, %{trace_id: "trace"})
    end

    test "executes action modules that happen to export flow/0 as actions" do
      module = unique_module("ActionWithFlowFunction")

      create_module(
        module,
        quote do
          use Jido.Action, name: "action_with_flow_function"

          def flow, do: :not_a_flow_artifact
          def run(params, _context), do: {:ok, Map.put(params, :executed_as, :action)}
        end
      )

      assert {:ok, %{value: 5, executed_as: :action}} = Exec.run(module, %{value: 5}, %{})
    end

    test "normalizes keyword input and context for leaf actions" do
      assert {:ok, %{value: 6}} = Exec.run(Add, [value: 5], trace_id: "trace")
    end

    test "preserves action extras from leaf actions" do
      assert {:ok, %{value: 5}, %{trace_id: "trace"}} =
               Exec.run(ExtrasAction, %{value: 5}, %{trace_id: "trace"})

      assert {:ok, %{value: 5}, :none} =
               Exec.run(NoneExtrasAction, %{value: 5}, %{})
    end

    test "validates explicit output envelopes from leaf actions" do
      assert {:ok, %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Exec.run(OutputEnvelopeAction, %{value: 3}, %{})
    end

    test "requires output envelopes for raw and stream values" do
      for value <- [42, Stream.map(1..3, & &1)] do
        assert {:error, %ExecutionFailureError{message: message, details: details}} =
                 Exec.run(RawOutputAction, %{value: value}, %{})

        assert message == "action returned a value that requires an output envelope"
        assert details.action == RawOutputAction
      end

      instruction =
        Instruction.new!(action: RawOutputWithExtrasAction, params: %{value: 42})

      for executable <- [RawOutputWithExtrasAction, instruction] do
        assert {:error, %ExecutionFailureError{}, %{effect: :already_ran}} =
                 Exec.run(executable, %{value: 42}, %{})
      end
    end

    test "validates action params before calling run" do
      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(Add, %{value: "bad"}, %{})

      assert message =~ "expected integer"
    end

    test "returns action errors without Runic-specific wrapping" do
      assert {:error, %ExecutionFailureError{message: message}} =
               Exec.run(ErrorAction, %{error_type: :validation}, %{})

      refute message =~ "Runic"
    end

    test "normalizes three-element action error tuples" do
      assert {:error, %ExecutionFailureError{message: message, details: details}, extras} =
               Exec.run(ErrorWithExtrasAction, %{reason: :bad_with_extras}, %{})

      assert message == "bad_with_extras"
      assert details.reason == :bad_with_extras
      assert extras == %{ignored: true}
    end

    test "preserves exception action errors returned by leaf actions" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ExceptionErrorAction, %{}, %{})

      assert message == "already wrapped"
      assert details.source == :test
    end

    test "normalizes atom and tuple action error reasons" do
      assert {:error, %ExecutionFailureError{message: "bad_atom"}} =
               Exec.run(AtomErrorAction, %{}, %{})

      assert {:error, %ExecutionFailureError{message: "{:bad, :tuple}"}} =
               Exec.run(TupleErrorAction, %{}, %{})
    end

    test "converts raised leaf action exceptions to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ErrorAction, %{error_type: :runtime}, %{})

      assert message =~ "Runtime error"
      assert details.action == ErrorAction
      assert details.exception == RuntimeError
    end

    test "converts unsupported action result shapes to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(UnsupportedResult)

      assert message =~ "action returned an unsupported result"
      assert details.action == UnsupportedResult
      assert details.result == :not_a_result_tuple
    end

    test "converts thrown action values to execution errors" do
      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(ThrowingAction)

      assert message =~ "action throw"
      assert details.action == ThrowingAction
      assert details.reason == :thrown_value
    end

    test "normalizes validator failures and unsupported results" do
      assert {:error, %ExecutionFailureError{message: "bad_params"}} =
               Exec.run(AtomValidationAction)

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Exec.run(InvalidValidationResultAction)

      assert message == "action validator returned an unsupported result"
      assert details.callback == :validate_params
      assert details.result == :ok

      assert {:error, %ExecutionFailureError{message: "validator failed", details: details}} =
               Exec.run(RaisingValidationAction)

      assert details.callback == :validate_params

      assert {:error,
              %ExecutionFailureError{message: "output validator failed", details: details}} =
               Exec.run(RaisingOutputValidationAction)

      assert details.callback == :validate_output

      for {action, callback} <- [
            {InvalidValidatedParamsAction, :validate_params},
            {InvalidValidatedOutputAction, :validate_output}
          ] do
        assert {:error, %ExecutionFailureError{details: details}} = Exec.run(action)
        assert details.callback == callback
        assert details.result == 42
      end
    end
  end

  describe "run/3 with instructions" do
    test "executes an instruction and merges call-site input and context" do
      instruction =
        Instruction.new!(
          action: Add,
          params: %{value: 5, amount: 1},
          context: %{trace_id: "base"}
        )

      assert {:ok, %{value: 8}} =
               Exec.run(instruction, %{amount: 3}, %{tenant_id: "tenant"})
    end

    test "returns validation errors when instruction call-site input is invalid" do
      instruction = Instruction.new!(action: Add)

      assert {:error, %InvalidInputError{message: message}} =
               Exec.run(instruction, :not_params, %{})

      assert message =~ "expected params to be a map or keyword list"
    end

    test "returns validation errors for malformed raw instruction structs" do
      instruction = %Instruction{action: "not_a_module", params: %{}, context: %{}}

      assert {:error, %InvalidInputError{message: "Invalid instruction configuration"}} =
               Exec.run(instruction)
    end
  end

  describe "run/3 with flows" do
    test "validates marked Flow modules exactly once in every execution path" do
      module = unique_module("CountedValidationFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "counted_validation_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:output]})

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{
                value: input(:value),
                input_passes: input(:input_passes)
              }
            )
          end
        end
      )

      for {path, run} <- flow_execution_paths(module, value: 3) do
        reset_flow_transform_counts()

        assert {:ok, %{value: 3, input_passes: 1, output_passes: 1}} =
                 run.(),
               to_string(path)

        assert Process.get({__MODULE__, :input}) == 1, to_string(path)
        assert Process.get({__MODULE__, :output}) == 1, to_string(path)
      end
    end

    test "rejects scalar Flow output transforms in every execution path" do
      module = unique_module("ScalarTransformedOutputFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "scalar_transformed_output_flow",
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:invalid_output]})

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{value: input(:value)}
            )
          end
        end
      )

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
        assert Process.get({__MODULE__, :invalid_output}) == 1, to_string(path)
      end
    end

    test "rejects scalar Flow input transforms in every execution path" do
      module = unique_module("ScalarTransformedInputFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "scalar_transformed_input_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:invalid_input]})

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{value: input(:value)}
            )
          end
        end
      )

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
        assert Process.get({__MODULE__, :invalid_input}) == 1, to_string(path)
      end
    end

    test "passes Flow output envelopes unchanged and bypasses the normal output schema" do
      module = unique_module("EnvelopeFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "envelope_flow",
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:envelope_output]})

          flow do
            step("envelope",
              action: unquote(OutputEnvelopeAction),
              params: %{value: input(:value)}
            )
          end
        end
      )

      expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}

      for {path, run} <- flow_execution_paths(module, %{value: 3}) do
        reset_flow_transform_counts()

        assert {:ok, ^expected} = run.(), to_string(path)
        assert Process.get({__MODULE__, :envelope_output}, 0) == 0, to_string(path)
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
      module = unique_module("ScalarResultFlow")

      create_module(
        module,
        quote do
          use Jido.Flow, name: "scalar_result_flow"

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{value: input(:value)}
            )

            output(select(result("echo"), [:value]))
          end
        end
      )

      for {path, run} <- flow_execution_paths(module, %{value: 3}) do
        assert {:error, %ExecutionFailureError{message: message}} = run.(), to_string(path)

        assert message == "action returned a value that requires an output envelope",
               to_string(path)
      end
    end

    test "uses zero-based result indexes in run-to-completion and step-wise execution" do
      module = unique_module("ListOutputAction")

      create_module(
        module,
        quote do
          use Jido.Action, name: "list_output_action"

          @impl true
          def run(_params, _context), do: {:ok, %{items: [%{value: 1}, %{value: 2}]}}
        end
      )

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
      module = unique_module("ShortListOutputAction")

      create_module(
        module,
        quote do
          use Jido.Action, name: "short_list_output_action"

          @impl true
          def run(_params, _context), do: {:ok, %{items: [%{value: 1}]}}
        end
      )

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
      module = unique_module("ImproperListOutputAction")

      create_module(
        module,
        quote do
          use Jido.Action, name: "improper_list_output_action"

          @impl true
          def run(_params, _context) do
            {:ok, unquote(Output).raw(%{items: [%{value: 1} | :tail]})}
          end
        end
      )

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
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())
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
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

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
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

      assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, :not_input, %{})
      assert message =~ "input must be a map or keyword list"

      assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, %{}, :not_context)
      assert message =~ "context must be a map or keyword list"

      assert {:error, %InvalidInputError{message: message}} = Exec.run(flow, [:not_keyword], %{})
      assert message =~ "expected a map or keyword list"
    end

    test "executes a Flow module and the equivalent Flow artifact with the same result" do
      module = unique_module("ExecMathFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "math_flow",
            description: "Adds one and doubles the result"

          flow do
            step("add_one",
              action: unquote(Add),
              params: %{value: input(:value), amount: 1}
            )

            step("double",
              action: unquote(JidoTest.TestActions.Multiply),
              params: %{
                value: select(result("add_one"), [:value]),
                amount: 2
              }
            )
          end
        end
      )

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

    test "runs the selected nested Flow validation boundary exactly once" do
      target = unique_module("ChoiceNestedFlow")

      create_module(
        target,
        quote do
          use Jido.Flow,
            name: "choice_nested_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:output]})

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{
                value: input(:value),
                input_passes: input(:input_passes)
              }
            )
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_nested_once",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target,
                  input: %{value: Ref.value(3)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      reset_flow_transform_counts()

      assert {:ok, %{value: 3, input_passes: 1, output_passes: 1}} = Exec.run(flow, %{}, %{})
      assert Process.get({__MODULE__, :input}) == 1
      assert Process.get({__MODULE__, :output}) == 1
    end

    test "preserves a selected nested Flow Output envelope and its input transform boundary" do
      target = unique_module("ChoiceNestedEnvelopeFlow")

      create_module(
        target,
        quote do
          use Jido.Flow,
            name: "choice_nested_envelope_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:envelope_output]})

          flow do
            step("envelope",
              action: unquote(OutputEnvelopeAction),
              params: %{value: input(:value)}
            )
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_nested_envelope",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target,
                  input: %{value: Ref.value(3)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      reset_flow_transform_counts()

      assert {:ok, %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Exec.run(flow, %{}, %{})

      assert Process.get({__MODULE__, :input}) == 1
      assert Process.get({__MODULE__, :envelope_output}, 0) == 0
    end

    test "keeps a selected nested Flow error class and reason with Choice execution metadata" do
      target = unique_module("ChoiceNestedErrorFlow")

      create_module(
        target,
        quote do
          use Jido.Flow, name: "choice_nested_error_flow"

          flow do
            step("fail",
              action: unquote(ErrorAction),
              params: %{error_type: :validation}
            )
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_nested_error",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:error, %ExecutionFailureError{message: "Validation error", details: details}} =
               Exec.run(flow, %{}, %{})

      assert details.reason == "Validation error"
      assert details.phase == :choice_target_execution
      assert details.node == "route"
      assert details.option == "nested"
      assert details.target == target
    end

    test "runs selected leaf Action validation and work exactly once" do
      target = unique_module("ChoiceCountedAction")

      create_module(
        target,
        quote do
          def validate_params(%{test_pid: test_pid} = params) do
            send(test_pid, {__MODULE__, :params})
            {:ok, params}
          end

          def validate_output(%{test_pid: test_pid} = output) do
            send(test_pid, {__MODULE__, :output})
            {:ok, output}
          end

          def run(%{test_pid: test_pid} = params, _context) do
            send(test_pid, {__MODULE__, :run})
            {:ok, params}
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_leaf_once",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target,
                  input: %{value: Ref.value(3), test_pid: Ref.context(:test_pid)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{value: 3, test_pid: _test_pid}} = Exec.run(flow, %{}, %{test_pid: self()})
      assert_receive {^target, :params}
      assert_receive {^target, :run}
      assert_receive {^target, :output}
      refute_receive {^target, _kind}
    end

    test "selects the same Choice option through every public Flow path" do
      module = unique_module("ChoicePublicPaths")

      create_module(
        module,
        quote do
          use Jido.Flow, name: "choice_public_paths"

          flow do
            choice "route" do
              option "priority" do
                condition(input(:kind) == :priority)
                action(unquote(Add))
                params(%{value: input(:value), amount: 1})
              end

              otherwise(
                action: unquote(Add),
                params: %{value: input(:value), amount: 2}
              )
            end
          end
        end
      )

      for {path, run} <- flow_execution_paths(module, %{kind: :priority, value: 3}) do
        assert {:ok, %{value: 4}} = run.(), to_string(path)
      end
    end

    test "preserves a selected Choice Action Output envelope through every public Flow path" do
      module = unique_module("ChoiceEnvelopePublicPaths")
      target = unique_module("ChoiceEnvelopeTarget")

      create_module(
        target,
        quote do
          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}

          def run(%{value: value}, _context) do
            {:ok, Jido.Action.Output.raw(%{value: value}, meta: %{source: :test})}
          end
        end
      )

      create_module(
        module,
        quote do
          use Jido.Flow, name: "choice_envelope_public_paths"

          flow do
            choice "route" do
              option "envelope" do
                condition(input(:kind) == :envelope)
                action(unquote(target))
                params(%{value: input(:value)})
              end

              otherwise(
                action: unquote(Add),
                params: %{value: input(:value), amount: 0}
              )
            end
          end
        end
      )

      expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}

      for {path, run} <- flow_execution_paths(module, %{kind: :envelope, value: 3}) do
        assert {:ok, ^expected} = run.(), to_string(path)
      end
    end

    test "runs selected nested Flow transforms exactly once through every public Flow path" do
      target = unique_module("ChoicePublicNestedFlow")
      module = unique_module("ChoicePublicNestedPaths")

      create_module(
        target,
        quote do
          use Jido.Flow,
            name: "choice_public_nested_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:output]})

          flow do
            step("echo",
              action: unquote(Add),
              params: %{value: input(:value), amount: 0}
            )
          end
        end
      )

      create_module(
        module,
        quote do
          use Jido.Flow, name: "choice_public_nested_paths"

          flow do
            choice "route" do
              option "nested" do
                condition(input(:kind) == :nested)
                action(unquote(target))
                params(%{value: input(:value)})
              end

              otherwise(
                action: unquote(Add),
                params: %{value: input(:value), amount: 0}
              )
            end
          end
        end
      )

      for {path, run} <- flow_execution_paths(module, %{kind: :nested, value: 3}) do
        reset_flow_transform_counts()

        assert {:ok, %{value: 3, output_passes: 1}} = run.(), to_string(path)
        assert Process.get({__MODULE__, :input}) == 1, to_string(path)
        assert Process.get({__MODULE__, :output}) == 1, to_string(path)
      end
    end

    test "preserves selected nested Flow Output envelopes through every public Flow path" do
      envelope = unique_module("ChoicePublicEnvelopeAction")
      target = unique_module("ChoicePublicEnvelopeFlow")
      module = unique_module("ChoicePublicEnvelopePaths")

      create_module(
        envelope,
        quote do
          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}

          def run(%{value: value}, _context) do
            {:ok, Jido.Action.Output.raw(%{value: value}, meta: %{source: :nested})}
          end
        end
      )

      create_module(
        target,
        quote do
          use Jido.Flow,
            name: "choice_public_envelope_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:envelope_output]})

          flow do
            step("envelope",
              action: unquote(envelope),
              params: %{value: input(:value)}
            )
          end
        end
      )

      create_module(
        module,
        quote do
          use Jido.Flow, name: "choice_public_envelope_paths"

          flow do
            choice "route" do
              option "nested" do
                condition(input(:kind) == :nested)
                action(unquote(target))
                params(%{value: input(:value)})
              end

              otherwise(
                action: unquote(Add),
                params: %{value: input(:value), amount: 0}
              )
            end
          end
        end
      )

      expected = %Jido.Action.Output{kind: :raw, value: %{value: 3}, meta: %{source: :nested}}

      for {path, run} <- flow_execution_paths(module, %{kind: :nested, value: 3}) do
        reset_flow_transform_counts()

        assert {:ok, ^expected} = run.(), to_string(path)
        assert Process.get({__MODULE__, :input}) == 1, to_string(path)
        assert Process.get({__MODULE__, :envelope_output}, 0) == 0, to_string(path)
      end
    end

    test "rejects an invalid unselected Choice target before graph execution" do
      before = unique_module("ChoicePreflightRecorder")

      create_module(
        before,
        quote do
          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}

          def run(%{test_pid: test_pid} = params, _context) do
            send(test_pid, {__MODULE__, :run})
            {:ok, params}
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_preflight",
          nodes: [
            Node.new!(
              name: :before_choice,
              action: before,
              input: %{test_pid: Ref.context(:test_pid)}
            ),
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: Add,
                  input: %{value: Ref.input(:value), amount: Ref.value(0)}
                ],
                [
                  name: :invalid,
                  condition: Condition.eq(Ref.value(false), Ref.value(true)),
                  action: MissingRun,
                  input: %{value: Ref.input(:value)}
                ]
              ],
              fallback: [action: Add, input: %{value: Ref.input(:value), amount: Ref.value(0)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{test_pid: self()})

      assert message == "module is not a valid Jido action"
      assert details.reason == "missing run/2"
      assert details.choice == "route"
      assert details.option == "invalid"
      assert details.target == MissingRun
      refute_receive {^before, :run}
    end

    test "does not validate or run an unselected Choice target" do
      target = unique_module("ChoiceUnselectedTarget")

      create_module(
        target,
        quote do
          def validate_params(%{test_pid: test_pid} = params) do
            send(test_pid, {__MODULE__, :params})
            {:ok, params}
          end

          def validate_output(%{test_pid: test_pid} = output) do
            send(test_pid, {__MODULE__, :output})
            {:ok, output}
          end

          def run(%{test_pid: test_pid} = params, _context) do
            send(test_pid, {__MODULE__, :run})
            {:ok, params}
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_unselected_target",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: Add,
                  input: %{value: Ref.value(3), amount: Ref.value(0)}
                ],
                [
                  name: :unselected,
                  condition: Condition.eq(Ref.value(false), Ref.value(true)),
                  action: target,
                  input: %{test_pid: Ref.context(:test_pid)}
                ]
              ],
              fallback: [action: Add, input: %{value: Ref.value(0), amount: Ref.value(0)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{value: 3}} = Exec.run(flow, %{}, %{test_pid: self()})
      refute_receive {^target, _kind}
    end

    test "runs each nested Map Flow input and output boundary exactly once" do
      target = unique_module("MapNestedFlow")

      create_module(
        target,
        quote do
          use Jido.Flow,
            name: "map_nested_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:output]})

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{
                value: input(:value),
                input_passes: input(:input_passes)
              }
            )
          end
        end
      )

      flow =
        Flow.new!(
          name: "map_nested_once",
          nodes: [
            FlowMap.new!(
              name: :mapped,
              collection: Ref.value([3, 4]),
              action: target,
              input: %{value: Ref.item()}
            )
          ],
          return: Ref.result(:mapped)
        )

      reset_flow_transform_counts()

      assert {:ok, %{results: results, errors: []}} = Exec.run(flow)
      assert Enum.map(results, & &1.output.value) == [3, 4]
      assert Enum.map(results, & &1.output.input_passes) == [1, 1]
      assert Enum.map(results, & &1.output.output_passes) == [1, 1]
      assert Process.get({__MODULE__, :input}) == 2
      assert Process.get({__MODULE__, :output}) == 2
    end

    test "runs each nested Reduce Flow input and output boundary exactly once" do
      target = unique_module("ReduceNestedFlow")

      create_module(
        target,
        quote do
          use Jido.Flow,
            name: "reduce_nested_flow",
            schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:input]}),
            output_schema:
              Zoi.map()
              |> Zoi.transform({Jido.ExecTest, :count_flow_transform, [:output]})

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: %{
                value: input(:value),
                previous: input(:previous),
                input_passes: input(:input_passes)
              }
            )
          end
        end
      )

      flow =
        Flow.new!(
          name: "reduce_nested_once",
          nodes: [
            Reduce.new!(
              name: :reduced,
              collection: Ref.value([3, 4]),
              initial: Ref.value(%{value: nil}),
              action: target,
              input: %{
                value: Ref.item(),
                previous: Ref.accumulator(:value)
              }
            )
          ],
          return: Ref.result(:reduced)
        )

      reset_flow_transform_counts()

      assert {:ok,
              %{
                value: 4,
                previous: 3,
                input_passes: 1,
                output_passes: 1
              }} = Exec.run(flow)

      assert Process.get({__MODULE__, :input}) == 2
      assert Process.get({__MODULE__, :output}) == 2
    end

    test "preflights an empty Map target before any public node runs" do
      before = unique_module("BeforeInvalidMap")

      create_module(
        before,
        quote do
          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}

          def run(%{test_pid: test_pid} = params, _context) do
            send(test_pid, {__MODULE__, :run})
            {:ok, params}
          end
        end
      )

      flow =
        Flow.new!(
          name: "empty_map_preflight",
          nodes: [
            Node.new!(
              name: :before,
              action: before,
              input: %{test_pid: Ref.context(:test_pid)}
            ),
            FlowMap.new!(
              name: :mapped,
              collection: Ref.value([]),
              action: MissingRun,
              input: Ref.item()
            )
          ],
          return: Ref.result(:mapped)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{}, %{test_pid: self()})

      assert message == "module is not a valid Jido action"
      assert details.map == "mapped"
      assert details.target == MissingRun
      refute_receive {^before, :run}
    end

    test "preflights an empty Reduce target before any public node runs" do
      before = unique_module("BeforeInvalidReduce")

      create_module(
        before,
        quote do
          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}

          def run(%{test_pid: test_pid} = params, _context) do
            send(test_pid, {__MODULE__, :run})
            {:ok, params}
          end
        end
      )

      flow =
        Flow.new!(
          name: "empty_reduce_preflight",
          nodes: [
            Node.new!(
              name: :before,
              action: before,
              input: %{test_pid: Ref.context(:test_pid)}
            ),
            Reduce.new!(
              name: :reduced,
              collection: Ref.value([]),
              initial: Ref.value(%{}),
              action: MissingRun,
              input: Ref.accumulator()
            )
          ],
          return: Ref.result(:reduced)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{}, %{test_pid: self()})

      assert message == "module is not a valid Jido action"
      assert details.reduce == "reduced"
      assert details.target == MissingRun
      refute_receive {^before, :run}
    end
  end

  describe "run/4 options" do
    @tag timeout: 5_000
    test "keeps an independent sibling asynchronous beside a Choice" do
      flow =
        Flow.new!(
          name: "choice_async_sibling",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :selected,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: DelayedEchoAction,
                  input: %{side: Ref.value(:choice), sleep_ms: Ref.value(100)}
                ]
              ],
              fallback: [action: EchoParamsAction]
            ),
            Node.new!(
              name: :sibling,
              action: DelayedEchoAction,
              input: %{side: Ref.value(:sibling), sleep_ms: Ref.value(100)}
            )
          ],
          return: %{choice: Ref.result(:route, :side), sibling: Ref.result(:sibling, :side)}
        )

      assert {{:ok, %{choice: :choice, sibling: :sibling}}, serial_ms} =
               timed(fn -> Exec.run(flow, %{}, %{}) end)

      assert {{:ok, %{choice: :choice, sibling: :sibling}}, async_ms} =
               timed(fn -> Exec.run(flow, %{}, %{}, async: true, max_concurrency: 2) end)

      assert async_ms < serial_ms * 0.75
    end

    @tag timeout: 5_000
    test "does not pass parent run options into a selected nested Flow" do
      target = unique_module("ChoiceNestedRunOptions")
      delayed = unique_module("ChoiceNestedDelayedAction")

      create_module(
        delayed,
        quote do
          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}

          def run(%{sleep_ms: sleep_ms} = params, _context) do
            Process.sleep(sleep_ms)
            {:ok, params}
          end
        end
      )

      create_module(
        target,
        quote do
          use Jido.Flow, name: "choice_nested_run_options"

          flow do
            step("left",
              action: unquote(delayed),
              params: %{side: :left, sleep_ms: 100}
            )

            step("right",
              action: unquote(delayed),
              params: %{side: :right, sleep_ms: 100}
            )

            output(%{
              left: select(result("left"), [:side]),
              right: select(result("right"), [:side])
            })
          end
        end
      )

      flow =
        Flow.new!(
          name: "choice_parent_run_options",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :nested,
                  condition: Condition.eq(Ref.value(true), Ref.value(true)),
                  action: target
                ]
              ],
              fallback: [action: EchoParamsAction]
            )
          ],
          return: Ref.result(:route)
        )

      assert {{:ok, %{left: :left, right: :right}}, elapsed_ms} =
               timed(fn -> Exec.run(flow, %{}, %{}, async: true, max_concurrency: 2) end)

      assert elapsed_ms >= 180
    end

    @tag timeout: 5_000
    test "runs independent flow branches concurrently when async is enabled" do
      flow =
        Flow.new!(
          name: "async_overlap",
          nodes: [
            Node.new!(
              name: :left,
              action: DelayedEchoAction,
              input: %{side: Ref.value(:left), sleep_ms: Ref.value(100)}
            ),
            Node.new!(
              name: :right,
              action: DelayedEchoAction,
              input: %{side: Ref.value(:right), sleep_ms: Ref.value(100)}
            ),
            Node.new!(
              name: :merge,
              action: EchoParamsAction,
              input: %{
                left: Ref.result(:left, :side),
                right: Ref.result(:right, :side)
              }
            )
          ],
          return: Ref.result(:merge)
        )

      assert {{:ok, %{left: :left, right: :right}}, serial_ms} =
               timed(fn -> Exec.run(flow, %{}, %{}) end)

      assert {{:ok, %{left: :left, right: :right}}, async_ms} =
               timed(fn -> Exec.run(flow, %{}, %{}, async: true, max_concurrency: 2) end)

      assert async_ms < serial_ms * 0.75
    end

    test "run/3 and run/4 with empty options are equivalent" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

      assert Exec.run(flow, %{value: 3}, %{}) == Exec.run(flow, %{value: 3}, %{}, [])
    end

    @tag capture_log: true
    test "returns async branch failures by flow node order" do
      flow =
        Flow.new!(
          name: "async_failure_order",
          nodes: [
            Node.new!(
              name: :first,
              action: DelayedErrorAction,
              input: %{sleep_ms: Ref.value(80), message: Ref.value("first failure")}
            ),
            Node.new!(
              name: :second,
              action: DelayedErrorAction,
              input: %{sleep_ms: Ref.value(10), message: Ref.value("second failure")}
            )
          ],
          return: Ref.result(:first)
        )

      assert {:error, %ExecutionFailureError{message: "first failure", details: details}} =
               Exec.run(flow, %{}, %{}, async: true, max_concurrency: 2)

      assert details.node == "first"
      assert details.action == DelayedErrorAction
    end

    test "executes Flow modules with runtime options" do
      module = unique_module("ExecAsyncMathFlow")

      create_module(
        module,
        quote do
          use Jido.Flow,
            name: "async_math_flow",
            description: "Runs through Exec options"

          flow do
            step("add_one",
              action: unquote(Add),
              params: %{value: input(:value), amount: 1}
            )
          end
        end
      )

      assert {:ok, %{value: 4}} = Exec.run(module, %{value: 3}, %{}, async: true)
    end

    test "rejects unknown Flow run options" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{}, timeout: 100)

      assert message =~ "unknown run option"
      assert details.option == :timeout
    end

    test "rejects invalid Flow run option values" do
      assert {:ok, flow} = Builder.build(FlowFixtures.math_builder())

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{}, async: :yes)

      assert message =~ "async option must be a boolean"
      assert details.option == :async

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(flow, %{value: 3}, %{}, max_concurrency: 0)

      assert message =~ "max_concurrency option must be a positive integer"
      assert details.option == :max_concurrency

      assert {:error, %InvalidInputError{message: "run options must be a keyword list"}} =
               Exec.run(flow, %{}, %{}, :not_options)
    end

    test "rejects Flow run options for action and instruction executables" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(Add, %{value: 1}, %{}, async: true)

      assert message =~ "run options are only supported for flows"
      assert details.executable_type == :action

      instruction = Instruction.new!(action: Add, params: %{value: 1})

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Exec.run(instruction, %{}, %{}, async: true)

      assert message =~ "run options are only supported for flows"
      assert details.executable_type == :instruction
    end
  end

  test "rejects unknown executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message}} = Exec.run(:not_a_real_executable)
    assert message =~ "unknown executable"
  end

  test "rejects unsupported executable values with a configuration error" do
    assert {:error, %ConfigurationError{message: message, details: details}} =
             Exec.run("not executable")

    assert message =~ "unknown executable"
    assert details.executable == "not executable"
  end

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed_ms = System.monotonic_time(:millisecond) - start
    {result, elapsed_ms}
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
    for kind <- [:input, :invalid_input, :output, :envelope_output, :invalid_output] do
      Process.delete({__MODULE__, kind})
    end
  end
end
