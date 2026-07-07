defmodule Jido.Flow.CompilerTest do
  use JidoTest.ActionCase, async: true
  @moduletag capture_log: true

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Action.Output
  alias Jido.Flow
  alias Jido.Flow.{Compiler, Node, Ref}
  alias Jido.Flow.NodeError
  alias JidoTest.FlowFixtures

  alias JidoTest.TestActions.{
    Add,
    AnyEchoAction,
    AtomErrorAction,
    AtomValidationAction,
    ContextEcho,
    EchoParamsAction,
    ErrorAction,
    ErrorWithExtrasAction,
    ExceptionErrorAction,
    ExtrasAction,
    FullAction,
    InvalidOutput,
    MissingRun,
    Multiply,
    OutputEnvelopeAction,
    RawExceptionErrorAction,
    RecorderAction,
    ThrowingAction,
    TupleErrorAction,
    UnsupportedResult
  }

  alias Runic.Workflow
  alias Runic.Workflow.Step

  describe "compile/1" do
    test "compiles a one-step flow to a Runic workflow with a named action component" do
      flow = one_step_flow()

      assert {:ok, workflow} = Flow.compile(flow)
      assert %Workflow{} = workflow
      assert Workflow.get_component(workflow, :add_one)
      assert workflow |> Workflow.steps() |> Enum.map(& &1.name) == [:add_one]
    end

    test "compiles the math flow into dependency edges" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())
      assert {:ok, workflow} = Flow.compile(flow)

      assert root_child?(workflow, :add_one)
      assert connects?(workflow, :add_one, :double)
      refute root_child?(workflow, :double)
    end

    test "compiles root result-ref inputs into dependency edges" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.binding_builder())
      assert [_add_one, double] = Flow.to_map(flow).nodes
      assert double.deps == [:add_one]

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, :add_one)
      assert connects?(workflow, :add_one, :double)
    end

    test "compiles explicit canonical deps as actual graph edges" do
      flow =
        Flow.new!(
          name: "explicit_edges",
          nodes: [
            Node.new!(
              name: :audit_quote,
              action: EchoParamsAction,
              input: %{event: Ref.value("quoted")},
              deps: [:load_quote]
            ),
            Node.new!(
              name: :load_quote,
              action: EchoParamsAction,
              input: %{id: Ref.input(:quote_id)}
            ),
            Node.new!(
              name: :independent,
              action: EchoParamsAction,
              input: %{event: Ref.value("side")}
            )
          ],
          return: Ref.result(:audit_quote)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, :load_quote)
      assert root_child?(workflow, :independent)
      assert connects?(workflow, :load_quote, :audit_quote)
      refute connects?(workflow, :load_quote, :independent)
      refute connects?(workflow, :independent, :audit_quote)
    end

    test "compiles branch-grouped flows by actual deps without serializing siblings" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.branch_group_builder())
      assert {:ok, workflow} = Flow.compile(flow)

      assert root_child?(workflow, :load_cart)
      assert root_child?(workflow, :post_group_independent)
      assert connects?(workflow, :load_cart, :price_cart)
      assert connects?(workflow, :load_cart, :reserve_inventory)
      assert connects?(workflow, :price_cart, :audit_price)
      assert join_feeds?(workflow, [:price_cart, :reserve_inventory], :finalize)
      refute connects?(workflow, :price_cart, :reserve_inventory)
      refute connects?(workflow, :reserve_inventory, :price_cart)
    end

    test "defensively rejects unvalidated cyclic dependency graphs" do
      flow = %Flow{
        name: "cycle",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          Node.new!(
            name: :first,
            action: Add,
            input: %{value: Ref.input(:value)},
            deps: [:second]
          ),
          Node.new!(
            name: :second,
            action: Multiply,
            input: %{value: Ref.input(:value)},
            deps: [:first]
          )
        ],
        return: Ref.result(:second, :value),
        provenance: %{}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.compile(flow)

      assert message =~ "flow dependency graph contains a cycle"
      assert Enum.sort(details.nodes) == [:first, :second]
    end

    test "compiles independent branches as independent roots" do
      flow =
        Flow.new!(
          name: "serialized",
          nodes: [
            Node.new!(name: :first, action: Add, input: %{value: Ref.input(:value)}),
            Node.new!(name: :second, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:second, :value)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, :first)
      assert root_child?(workflow, :second)
      refute connects?(workflow, :first, :second)
      refute connects?(workflow, :second, :first)
    end

    test "compiles structurally valid flows without checking action contracts" do
      flow =
        Flow.new!(
          name: "shape_only_compile",
          nodes: [
            Node.new!(name: :broken, action: MissingRun)
          ],
          return: Ref.result(:broken)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, :broken)
    end

    test "compiles child-before-parent node lists by adding parents first" do
      flow =
        Flow.new!(
          name: "child_before_parent",
          nodes: [
            Node.new!(
              name: :child,
              action: EchoParamsAction,
              input: %{value: Ref.result(:parent, :value)}
            ),
            Node.new!(
              name: :parent,
              action: EchoParamsAction,
              input: %{value: Ref.input(:value)}
            )
          ],
          return: Ref.result(:child, :value)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, :parent)
      assert connects?(workflow, :parent, :child)
      refute root_child?(workflow, :child)
    end

    test "compiles multi-parent deps through a Runic join" do
      flow = diamond_flow()

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, :a)
      assert connects?(workflow, :a, :b)
      assert connects?(workflow, :a, :c)
      assert join_feeds?(workflow, [:b, :c], :d)
      refute connects?(workflow, :b, :c)
      refute connects?(workflow, :c, :b)
    end

    test "Runic settles raised work failures and skips downstream work" do
      workflow =
        Workflow.new("raised_work")
        |> Workflow.add(Step.new(name: :first, work: fn input -> input end), validate: :off)
        |> Workflow.add(Step.new(name: :bad, work: fn _state -> raise "boom" end),
          to: :first,
          validate: :off
        )
        |> Workflow.add(
          Step.new(
            name: :after_bad,
            work: fn state ->
              send(self(), {:after_bad, state})
              state
            end
          ),
          to: :bad,
          validate: :off
        )

      assert %Workflow{} = final_workflow = Workflow.react_until_satisfied(workflow, %{})
      assert Workflow.results(final_workflow, [:after_bad]) == %{after_bad: nil}
      refute_receive {:after_bad, _state}
    end
  end

  describe "run/3" do
    test "node error messages include the normalized error message" do
      assert_raise NodeError, ~r/flow node :bad failed: boom/, fn ->
        raise NodeError, node: :bad, error: %RuntimeError{message: "boom"}
      end
    end

    test "uses an empty context by default" do
      assert {:ok, 4} = Compiler.run(one_step_flow(), %{value: 3})
    end

    test "executes the compiled workflow and extracts the declared return" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())
      assert {:ok, 8} = Compiler.run(flow, %{value: 3}, %{})
    end

    test "executes a binding-first flow with whole-result step input" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.binding_builder())

      assert {:ok, %{value: 8}} = Compiler.run(flow, %{value: 3}, %{})
    end

    test "normalizes raw flow dependency metadata before execution" do
      flow = %Flow{
        name: "raw_dependencies",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          Node.new!(
            name: :add_one,
            action: Add,
            input: %{value: Ref.input(:value), amount: Ref.value(1)}
          ),
          Node.new!(
            name: :add_again,
            action: Add,
            input: %{value: Ref.result(:add_one, :value), amount: Ref.value(1)}
          )
        ],
        return: Ref.result(:add_again, :value),
        provenance: %{}
      }

      assert {:ok, 5} = Compiler.run(flow, %{value: 3}, %{})
    end

    test "checks action contracts before direct compiler execution" do
      flow =
        Flow.new!(
          name: "missing_action_contract",
          nodes: [
            Node.new!(name: :broken, action: MissingRun)
          ],
          return: Ref.result(:broken)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message =~ "module is not a valid Jido action"
      assert details.node == :broken
      assert details.action == MissingRun
      assert details.reason == "missing run/2"
    end

    test "passes list-valued single parent results unchanged" do
      flow =
        Flow.new!(
          name: "single_parent_list_result",
          nodes: [
            Node.new!(
              name: :source,
              action: AnyEchoAction,
              input: [Ref.value(:left), Ref.value(:right)]
            ),
            Node.new!(
              name: :child,
              action: AnyEchoAction,
              input: Ref.result(:source)
            )
          ],
          return: Ref.result(:child)
        )

      assert {:ok, [:left, :right]} = Compiler.run(flow, %{}, %{})
    end

    test "maps joined parent values to result refs by dependency order" do
      flow =
        Flow.new!(
          name: "join_order",
          nodes: [
            Node.new!(
              name: :a,
              action: EchoParamsAction,
              input: %{value: Ref.input(:value)}
            ),
            Node.new!(
              name: :b,
              action: EchoParamsAction,
              input: %{value: Ref.value("left"), parent: Ref.result(:a, :value)}
            ),
            Node.new!(
              name: :c,
              action: EchoParamsAction,
              input: %{value: Ref.value("right"), parent: Ref.result(:a, :value)}
            ),
            Node.new!(
              name: :d,
              action: EchoParamsAction,
              input: %{
                left: Ref.result(:b, :value),
                right: Ref.result(:c, :value)
              }
            )
          ],
          return: Ref.result(:d)
        )

      assert {:ok, %{left: "left", right: "right"}} = Compiler.run(flow, %{value: 1}, %{})
    end

    test "rejects non-map input or context" do
      flow = one_step_flow()

      assert {:error, %InvalidInputError{message: message}} = Compiler.run(flow, [], %{})
      assert message =~ "flow input and context must be maps"

      assert {:error, %InvalidInputError{message: message}} = Compiler.run(flow, %{}, [])
      assert message =~ "flow input and context must be maps"
    end

    test "resolves atom paths from atom or string keyed input maps" do
      flow = one_step_flow()

      assert {:ok, 4} = Compiler.run(flow, %{value: 3}, %{})
      assert {:ok, 4} = Compiler.run(flow, %{"value" => 3}, %{})
    end

    test "passes runtime context to action invocations without changing the canonical map" do
      flow =
        Flow.new!(
          name: "context",
          nodes: [
            Node.new!(name: :echo, action: ContextEcho, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:echo, :trace_id)
        )

      canonical = Flow.to_map(flow)

      assert {:ok, "trace-1"} = Compiler.run(flow, %{value: 3}, %{trace_id: "trace-1"})
      assert {:ok, "trace-2"} = Compiler.run(flow, %{value: 3}, %{trace_id: "trace-2"})
      assert Flow.to_map(flow) == canonical
    end

    test "resolves context refs through the existing path traversal contract" do
      flow =
        Flow.new!(
          name: "context_refs",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{
                trace_id: Ref.context(:trace_id),
                tenant_id: Ref.context([:tenant, :id]),
                string_key: Ref.context(:string_key),
                list_value: Ref.context([:items, 0, :value]),
                missing: Ref.context([:missing, :nested]),
                full_context: Ref.context(nil)
              }
            )
          ],
          return: Ref.result(:echo)
        )

      context = %{
        "string_key" => "string-value",
        trace_id: "trace-1",
        tenant: %{id: "tenant-1"},
        items: [%{value: 42}]
      }

      assert {:ok, result} = Compiler.run(flow, %{}, context)

      assert result == %{
               trace_id: "trace-1",
               tenant_id: "tenant-1",
               string_key: "string-value",
               list_value: 42,
               missing: nil,
               full_context: context
             }
    end

    test "context ref params change by runtime context while canonical maps stay stable" do
      flow =
        Flow.new!(
          name: "context_stability",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{trace_id: Ref.context(:trace_id)}
            )
          ],
          return: Ref.result(:echo, :trace_id)
        )

      canonical = Flow.to_map(flow)

      assert {:ok, "trace-1"} = Compiler.run(flow, %{}, %{trace_id: "trace-1"})
      assert {:ok, "trace-2"} = Compiler.run(flow, %{}, %{trace_id: "trace-2"})
      assert Flow.to_map(flow) == canonical
    end

    test "keeps the original runtime context when params also include context-derived values" do
      flow =
        Flow.new!(
          name: "context_params_and_action_context",
          nodes: [
            Node.new!(
              name: :echo,
              action: ContextEcho,
              input: %{value: Ref.context(:value)}
            )
          ],
          return: Ref.result(:echo)
        )

      assert {:ok, %{value: 3, trace_id: "trace-1"}} =
               Compiler.run(flow, %{}, %{value: 3, trace_id: "trace-1"})
    end

    test "ignores action extras from successful step result tuples" do
      flow =
        Flow.new!(
          name: "extras",
          nodes: [
            Node.new!(name: :extras, action: ExtrasAction, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:extras, :value)
        )

      assert {:ok, 3} = Compiler.run(flow, %{value: 3}, %{trace_id: "trace"})
    end

    test "normalizes three-element action error tuples with step metadata" do
      flow =
        Flow.new!(
          name: "error_with_extras",
          nodes: [
            Node.new!(
              name: :bad,
              action: ErrorWithExtrasAction,
              input: %{reason: Ref.value(:bad_with_extras)}
            )
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "bad_with_extras"
      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == ErrorWithExtrasAction
      assert details.reason == :bad_with_extras
    end

    test "resolves list expressions and literal values in step input" do
      flow =
        Flow.new!(
          name: "list_input",
          nodes: [
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: %{
                items: [Ref.input(:value), Ref.value(2), 3],
                literal: 4
              }
            )
          ],
          return: Ref.result(:echo, :items)
        )

      assert {:ok, [1, 2, 3]} = Compiler.run(flow, %{value: 1}, %{})
    end

    test "resolves integer path segments through input and result lists" do
      flow =
        Flow.new!(
          name: "list_path_refs",
          nodes: [
            Node.new!(
              name: :source,
              action: EchoParamsAction,
              input: %{items: Ref.input(:items)}
            ),
            Node.new!(
              name: :pick,
              action: EchoParamsAction,
              input: %{
                input_value: Ref.input([:items, 0, :value]),
                result_value: Ref.result(:source, [:items, 1, :value])
              }
            )
          ],
          return: Ref.result(:pick)
        )

      input = %{items: [%{value: 42}, %{value: 84}]}

      assert {:ok, %{input_value: 42, result_value: 84}} = Compiler.run(flow, input, %{})
    end

    test "executes projection-shaped flows through existing path traversal" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.projection_builder())

      input = %{quote_id: "quote-1", items: [%{id: "item-1", price: 42}], tag: "priority"}

      assert {:ok, 42} = Compiler.run(flow, input, %{})
    end

    test "returns validation errors for malformed refs inside nested inputs" do
      malformed_ref = %Ref{type: :unsupported}

      flow = %Flow{
        name: "malformed_ref",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          %Node{
            name: :echo,
            action: EchoParamsAction,
            input: %{values: [malformed_ref]},
            deps: [],
            provenance: %{}
          }
        ],
        return: Ref.result(:echo),
        provenance: %{}
      }

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message =~ "unsupported flow ref type"
      assert details.type == :unsupported
    end

    test "returns nil for missing and non-map nested return paths" do
      missing_nested_return =
        Flow.new!(
          name: "missing_nested_return",
          nodes: [
            Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:add_one, [:missing, :nested])
        )

      non_map_nested_return =
        Flow.new!(
          name: "non_map_nested_return",
          nodes: [
            Node.new!(name: :add_one, action: Add, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:add_one, [:value, :nested])
        )

      assert {:ok, nil} = Compiler.run(missing_nested_return, %{value: 3}, %{})
      assert {:ok, nil} = Compiler.run(non_map_nested_return, %{value: 3}, %{})
    end

    test "returns existing action validation errors for invalid step input" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: "bad"}, %{})

      assert message =~ "expected integer"
      assert details.phase == :step_input
      assert details.node == :add_one
      assert details.action == Add
    end

    test "returns existing action validation errors for invalid step output" do
      flow =
        Flow.new!(
          name: "invalid_output",
          nodes: [
            Node.new!(name: :invalid, action: InvalidOutput, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:invalid, :value)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{})

      assert message =~ "expected integer"
      assert details.phase == :step_output
      assert details.node == :invalid
      assert details.action == InvalidOutput
    end

    test "returns execution errors for unsupported action result tuples" do
      flow =
        Flow.new!(
          name: "unsupported_result",
          nodes: [
            Node.new!(name: :bad, action: UnsupportedResult)
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message =~ "action returned an unsupported result"
      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == UnsupportedResult
      assert details.result == :not_a_result_tuple
    end

    test "returns execution errors for action error tuples with step metadata" do
      flow =
        Flow.new!(
          name: "action_error",
          nodes: [
            Node.new!(
              name: :bad,
              action: ErrorAction,
              input: %{error_type: Ref.value(:validation)}
            )
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "Validation error"
      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == ErrorAction
      assert details.reason == "Validation error"
    end

    test "does not invoke downstream actions after a node failure" do
      flow =
        Flow.new!(
          name: "skip_downstream_after_error",
          nodes: [
            Node.new!(
              name: :add_one,
              action: Add,
              input: %{value: Ref.input(:value), amount: Ref.value(1)}
            ),
            Node.new!(
              name: :bad,
              action: ErrorAction,
              input: %{error_type: Ref.value(:validation)}
            ),
            Node.new!(
              name: :recorder,
              action: RecorderAction,
              input: Ref.result(:bad)
            )
          ],
          return: Ref.result(:recorder)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{test_pid: self()})

      assert message == "Validation error"
      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == ErrorAction
      refute_receive {RecorderAction, _params}
      refute_receive {_run_ref, :node_error, _node, _error}
    end

    test "node failure skips dependents while independent sibling branches still run" do
      flow =
        Flow.new!(
          name: "diamond_failure",
          nodes: [
            Node.new!(
              name: :a,
              action: EchoParamsAction,
              input: %{value: Ref.input(:value)}
            ),
            Node.new!(
              name: :b,
              action: ErrorAction,
              input: %{error_type: Ref.value(:validation)}
            ),
            Node.new!(
              name: :c,
              action: RecorderAction,
              input: %{value: Ref.result(:a, :value)}
            ),
            Node.new!(
              name: :d,
              action: RecorderAction,
              input: %{left: Ref.result(:b), right: Ref.result(:c)}
            )
          ],
          return: Ref.result(:d)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{test_pid: self()})

      assert message == "Validation error"
      assert details.phase == :step_execution
      assert details.node == :b
      assert details.action == ErrorAction
      assert_receive {RecorderAction, %{value: 3}}
      refute_receive {RecorderAction, %{left: _, right: _}}
    end

    test "root node failure does not stop independent root work" do
      flow =
        Flow.new!(
          name: "root_failure_independent",
          nodes: [
            Node.new!(
              name: :bad,
              action: ErrorAction,
              input: %{error_type: Ref.value(:validation)}
            ),
            Node.new!(
              name: :recorder,
              action: RecorderAction,
              input: %{value: Ref.input(:value)}
            )
          ],
          return: Ref.result(:recorder)
        )

      assert {:error, %ExecutionFailureError{message: "Validation error", details: details}} =
               Compiler.run(flow, %{value: 3}, %{test_pid: self()})

      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == ErrorAction
      assert_receive {RecorderAction, %{value: 3}}
    end

    test "preserves exception action errors returned by steps" do
      flow =
        Flow.new!(
          name: "exception_error",
          nodes: [
            Node.new!(name: :bad, action: ExceptionErrorAction)
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "already wrapped"
      assert details.source == :test
      assert details.phase == :step_execution
      assert details.node == :bad
      assert details.action == ExceptionErrorAction
    end

    test "preserves raw exception action errors returned by steps" do
      flow =
        Flow.new!(
          name: "raw_exception_error",
          nodes: [
            Node.new!(name: :bad, action: RawExceptionErrorAction)
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %RuntimeError{message: "raw exception"}} = Compiler.run(flow, %{}, %{})
    end

    test "normalizes atom and tuple action error reasons" do
      atom_error_flow =
        Flow.new!(
          name: "atom_error",
          nodes: [
            Node.new!(name: :bad, action: AtomErrorAction)
          ],
          return: Ref.result(:bad)
        )

      tuple_error_flow =
        Flow.new!(
          name: "tuple_error",
          nodes: [
            Node.new!(name: :bad, action: TupleErrorAction)
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: "bad_atom"}} =
               Compiler.run(atom_error_flow, %{}, %{})

      assert {:error, %ExecutionFailureError{message: "{:bad, :tuple}"}} =
               Compiler.run(tuple_error_flow, %{}, %{})
    end

    test "returns execution errors for thrown action values" do
      flow =
        Flow.new!(
          name: "throwing",
          nodes: [
            Node.new!(name: :throwing, action: ThrowingAction)
          ],
          return: Ref.result(:throwing)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message =~ "action throw"
      assert details.phase == :step_execution
      assert details.node == :throwing
      assert details.reason == :thrown_value
    end

    test "passes explicit output envelopes through output validation" do
      flow =
        Flow.new!(
          name: "output_envelope",
          nodes: [
            Node.new!(
              name: :envelope,
              action: OutputEnvelopeAction,
              input: %{value: Ref.input(:value)}
            )
          ],
          return: Ref.result(:envelope)
        )

      assert {:ok, %Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Compiler.run(flow, %{value: 3}, %{})
    end

    test "passes whole-result output envelopes unchanged to the next step" do
      flow =
        Flow.new!(
          name: "output_envelope_passthrough",
          nodes: [
            Node.new!(
              name: :envelope,
              action: OutputEnvelopeAction,
              input: %{value: Ref.input(:value)}
            ),
            Node.new!(
              name: :echo,
              action: EchoParamsAction,
              input: Ref.result(:envelope)
            )
          ],
          return: Ref.result(:echo)
        )

      assert {:ok, %Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Compiler.run(flow, %{value: 3}, %{})
    end

    test "returns step validation metadata for invalid whole-result params" do
      flow =
        Flow.new!(
          name: "invalid_whole_result_params",
          nodes: [
            Node.new!(
              name: :add_one,
              action: Add,
              input: %{value: Ref.input(:value), amount: Ref.value(1)}
            ),
            Node.new!(
              name: :full,
              action: FullAction,
              input: Ref.result(:add_one)
            )
          ],
          return: Ref.result(:full)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{})

      assert message =~ "required"
      assert details.phase == :step_input
      assert details.node == :full
      assert details.action == FullAction
    end

    test "normalizes non-exception validation failures with step metadata" do
      flow =
        Flow.new!(
          name: "atom_validation",
          nodes: [
            Node.new!(name: :bad_params, action: AtomValidationAction)
          ],
          return: Ref.result(:bad_params)
        )

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "bad_params"
      assert details.phase == :step_input
      assert details.node == :bad_params
      assert details.action == AtomValidationAction
      assert details.reason == :bad_params
    end
  end

  defp one_step_flow do
    Flow.new!(
      name: "one_step",
      nodes: [
        Node.new!(
          name: :add_one,
          action: Add,
          input: %{value: Ref.input(:value), amount: Ref.value(1)}
        )
      ],
      return: Ref.result(:add_one, :value)
    )
  end

  defp diamond_flow do
    Flow.new!(
      name: "diamond",
      nodes: [
        Node.new!(name: :a, action: EchoParamsAction, input: %{value: Ref.input(:value)}),
        Node.new!(name: :b, action: EchoParamsAction, input: %{value: Ref.result(:a, :value)}),
        Node.new!(name: :c, action: EchoParamsAction, input: %{value: Ref.result(:a, :value)}),
        Node.new!(
          name: :d,
          action: EchoParamsAction,
          input: %{left: Ref.result(:b, :value), right: Ref.result(:c, :value)}
        )
      ],
      return: Ref.result(:d)
    )
  end

  defp root_child?(workflow, node_name) do
    node = Workflow.get_component(workflow, node_name)

    Enum.any?(Multigraph.edges(workflow.graph, by: :flow), fn edge ->
      match?(%Runic.Workflow.Root{}, edge.v1) and edge.v2 == node
    end)
  end

  defp connects?(workflow, parent_name, child_name) do
    parent = Workflow.get_component(workflow, parent_name)
    child = Workflow.get_component(workflow, child_name)

    edge?(workflow, parent, child, :connects_to)
  end

  defp join_feeds?(workflow, parent_names, child_name) do
    parents = Enum.map(parent_names, &Workflow.get_component(workflow, &1))
    child = Workflow.get_component(workflow, child_name)

    workflow.graph
    |> Multigraph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Join{}, &1))
    |> Enum.any?(fn join ->
      Enum.all?(parents, &edge?(workflow, &1, join, :flow)) and
        edge?(workflow, join, child, :flow)
    end)
  end

  defp edge?(workflow, from, to, label) do
    Enum.any?(Multigraph.edges(workflow.graph, by: label), fn edge ->
      edge.v1 == from and edge.v2 == to
    end)
  end
end
