defmodule Jido.Flow.CompilerTest do
  use JidoTest.ActionCase, async: true
  @moduletag capture_log: true

  alias Jido.Action.Error.{ExecutionFailureError, InvalidInputError}
  alias Jido.Action.Output
  alias Jido.Flow
  alias Jido.Flow.{Choice, Compiler, Condition, ContractBundle, Identity, Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.NodeError
  alias JidoTest.FlowFixtures

  alias JidoTest.TestActions.{
    Add,
    AtomErrorAction,
    AtomValidationAction,
    ContextEcho,
    CountedMapAction,
    CountedReduceAction,
    EchoParamsAction,
    ErrorAction,
    ErrorWithExtrasAction,
    ExceptionErrorAction,
    ExtrasAction,
    FullAction,
    InvalidOutput,
    InvalidValidatedOutputAction,
    MissingRun,
    MapProbeAction,
    Multiply,
    OutputEnvelopeAction,
    RawExceptionErrorAction,
    RawOutputAction,
    RecorderAction,
    RejectingParamsAction,
    ReduceProbeAction,
    ThrowingAction,
    TupleErrorAction,
    UnsupportedResult
  }

  alias Runic.Workflow
  alias Runic.Workflow.Step

  describe "compile/1" do
    test "compiles Map and Reduce as two inert public Steps with one edge" do
      map_target = unique_module("UnloadedMapTarget")
      reduce_target = unique_module("UnloadedReduceTarget")
      assert {:error, :nofile} = Code.ensure_loaded(map_target)
      assert {:error, :nofile} = Code.ensure_loaded(reduce_target)

      flow =
        Flow.new!(
          name: "inert_map_reduce",
          nodes: [
            FlowMap.new!(
              name: :mapped,
              collection: Ref.input(:items),
              action: map_target,
              input: Ref.item()
            ),
            Reduce.new!(
              name: :reduced,
              collection: Ref.result(:mapped),
              initial: 0,
              action: reduce_target,
              input: Ref.accumulator()
            )
          ],
          return: Ref.result(:reduced)
        )

      assert {:ok, first} = Flow.compile(flow)
      assert {:ok, second} = Flow.compile(flow)

      assert Enum.map(Workflow.steps(first), &{&1.name, &1.hash}) ==
               Enum.map(Workflow.steps(second), &{&1.name, &1.hash})

      assert first |> Workflow.steps() |> Enum.map(& &1.name) |> Enum.sort() == [
               "mapped",
               "reduced"
             ]

      assert root_child?(first, "mapped")
      assert connects?(first, :mapped, :reduced)

      reacted = Workflow.react_until_satisfied(first, %{items: [:not_resolved]})

      assert Workflow.results(reacted, ["mapped", "reduced"]) == %{
               "mapped" => {:jido_flow_node, 1, "mapped"},
               "reduced" => {:jido_flow_node, 1, "reduced"}
             }

      assert {:error, :nofile} = Code.ensure_loaded(map_target)
      assert {:error, :nofile} = Code.ensure_loaded(reduce_target)
    end

    test "compiles a one-step flow to a Runic workflow with a named action component" do
      flow = one_step_flow()

      assert {:ok, workflow} = Flow.compile(flow)
      assert %Workflow{} = workflow
      assert Workflow.get_component(workflow, "add_one")
      assert workflow |> Workflow.steps() |> Enum.map(& &1.name) == ["add_one"]
    end

    test "compiles the math flow into dependency edges" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())
      assert {:ok, workflow} = Flow.compile(flow)

      assert root_child?(workflow, "add_one")
      assert connects?(workflow, :add_one, :double)
      refute root_child?(workflow, "double")
    end

    test "compiles root result-ref inputs into dependency edges" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.binding_builder())
      assert [_add_one, double] = Flow.to_map(flow).nodes
      assert double.deps == ["add_one"]

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, "add_one")
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
      assert root_child?(workflow, "load_quote")
      assert root_child?(workflow, "independent")
      assert connects?(workflow, :load_quote, :audit_quote)
      refute connects?(workflow, :load_quote, :independent)
      refute connects?(workflow, :independent, :audit_quote)
    end

    test "compiles branch-grouped flows by actual deps without serializing siblings" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.branch_group_builder())
      assert {:ok, workflow} = Flow.compile(flow)

      assert root_child?(workflow, "load_cart")
      assert root_child?(workflow, "post_group_independent")
      assert connects?(workflow, :load_cart, :price_cart)
      assert connects?(workflow, :load_cart, :reserve_inventory)
      assert connects?(workflow, :price_cart, :audit_price)
      assert join_feeds?(workflow, ["price_cart", "reserve_inventory"], "finalize")
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
      assert Enum.sort(details.nodes) == ["first", "second"]
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
      assert root_child?(workflow, "first")
      assert root_child?(workflow, "second")
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
      assert root_child?(workflow, "broken")
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
      assert root_child?(workflow, "parent")
      assert connects?(workflow, :parent, :child)
      refute root_child?(workflow, "child")
    end

    test "compiles multi-parent deps through a Runic join" do
      flow = diamond_flow()

      assert {:ok, workflow} = Flow.compile(flow)
      assert root_child?(workflow, "a")
      assert connects?(workflow, :a, :b)
      assert connects?(workflow, :a, :c)
      assert join_feeds?(workflow, ["b", "c"], "d")
      refute connects?(workflow, :b, :c)
      refute connects?(workflow, :c, :b)
    end

    test "reacts inspection workflows with inert node markers only" do
      flow =
        Flow.new!(
          name: "passive_inspection",
          nodes: [Node.new!(name: :probe, action: ThrowingAction)],
          return: Ref.result(:probe)
        )

      assert {:ok, workflow} = Flow.compile(flow)

      final_workflow = Workflow.react_until_satisfied(workflow, %{ignored: :runtime_input})

      assert Workflow.results(final_workflow, ["probe"]) == %{
               "probe" => {:jido_flow_node, 1, "probe"}
             }
    end

    test "does not load Action modules during compile or inspection reaction" do
      unloaded_action = unique_module("UnloadedInspectionAction")
      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)

      flow =
        Flow.new!(
          name: "unloaded_inspection",
          nodes: [Node.new!(name: :unloaded, action: unloaded_action)],
          return: Ref.result(:unloaded)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)

      final_workflow = Workflow.react_until_satisfied(workflow, %{})

      assert Workflow.results(final_workflow, ["unloaded"]) == %{
               "unloaded" => {:jido_flow_node, 1, "unloaded"}
             }

      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)
    end

    test "keeps stored decode and inspection inert until target checks or execution" do
      unloaded_action = unique_module("StoredUnloadedInspectionAction")
      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)

      flow =
        Flow.new!(
          name: "stored_unloaded_inspection",
          nodes: [Node.new!(name: :unloaded, action: unloaded_action)],
          return: Ref.result(:unloaded)
        )

      references = %{
        bundle: "compiler/inert/v1",
        input_schema: "compiler/inert-input/v1",
        output_schema: "compiler/inert-output/v1",
        action_registry: "compiler/inert-actions/v1"
      }

      bundle =
        ContractBundle.new!(
          id: references.bundle,
          schemas: %{
            references.input_schema => flow.schema,
            references.output_schema => flow.output_schema
          },
          action_registries: %{
            references.action_registry => %{"unloaded/v1" => unloaded_action}
          }
        )

      bundles = %{bundle.id => bundle}

      stored =
        Flow.to_map(flow,
          format: :stored,
          contracts: references,
          contract_bundles: bundles
        )

      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)
      assert {:ok, loaded} = Flow.from_map(stored, contract_bundles: bundles)
      assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)

      for inspect_flow <- [
            &Flow.dependencies/1,
            &Flow.explain/1,
            &Flow.semantic_identity/1,
            &Flow.compile/1
          ] do
        assert {:ok, _value} = inspect_flow.(loaded)
        assert {:error, :nofile} = Code.ensure_loaded(unloaded_action)
      end

      for check_target <- [&Flow.check/1, &Jido.Exec.run(&1, %{}, %{})] do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 check_target.(loaded)

        assert message == "action module could not be loaded"
        assert details.action == unloaded_action
        assert details.node == "unloaded"
      end
    end

    test "compiles Choice as one inert Step without loading its targets" do
      first_target = unique_module("UnloadedChoiceFirst")
      fallback_target = unique_module("UnloadedChoiceFallback")

      assert {:error, :nofile} = Code.ensure_loaded(first_target)
      assert {:error, :nofile} = Code.ensure_loaded(fallback_target)

      flow =
        Flow.new!(
          name: "inert_choice",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :first,
                  condition: Condition.eq(Ref.input(:kind), :first),
                  action: first_target
                ]
              ],
              fallback: [action: fallback_target]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert [%Step{name: "route", hash: hash}] = Workflow.steps(workflow)
      assert hash =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      final_workflow = Workflow.react_until_satisfied(workflow, %{})

      assert Workflow.results(final_workflow, ["route"]) == %{
               "route" => {:jido_flow_node, 1, "route"}
             }

      assert {:error, :nofile} = Code.ensure_loaded(first_target)
      assert {:error, :nofile} = Code.ensure_loaded(fallback_target)
    end

    test "gives mixed Action and Choice Steps stable unique identities" do
      flow = mixed_choice_flow([:first, :second])
      reordered = mixed_choice_flow([:second, :first])

      assert {:ok, first} = Flow.compile(flow)
      assert {:ok, second} = Flow.compile(flow)
      assert {:ok, reordered_workflow} = Flow.compile(reordered)

      first_hashes = Map.new(Workflow.steps(first), &{&1.name, &1.hash})
      second_hashes = Map.new(Workflow.steps(second), &{&1.name, &1.hash})
      reordered_hashes = Map.new(Workflow.steps(reordered_workflow), &{&1.name, &1.hash})

      assert first_hashes == second_hashes
      assert map_size(first_hashes) == first_hashes |> Map.values() |> Enum.uniq() |> length()
      refute first_hashes["route"] == reordered_hashes["route"]
    end

    test "uses stable node-unique UUIDv8 hashes for inspection Steps" do
      flow = diamond_flow()

      assert {:ok, first_workflow} = Flow.compile(flow)
      assert {:ok, second_workflow} = Flow.compile(flow)

      first_hashes = Map.new(Workflow.steps(first_workflow), &{&1.name, &1.hash})
      second_hashes = Map.new(Workflow.steps(second_workflow), &{&1.name, &1.hash})

      assert first_hashes == second_hashes
      assert first_hashes["a"] == "a333a789-9129-8feb-8c73-3bef0bb22beb"
      assert map_size(first_hashes) == first_hashes |> Map.values() |> Enum.uniq() |> length()

      for hash <- Map.values(first_hashes) do
        assert hash =~
                 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      end

      changed_flow = %{flow | description: "semantic change"}
      assert {:ok, changed_workflow} = Flow.compile(changed_flow)

      changed_hashes = Map.new(Workflow.steps(changed_workflow), &{&1.name, &1.hash})
      refute first_hashes == changed_hashes
    end

    test "uses canonical node order for independent inspection Steps" do
      flow =
        Flow.new!(
          name: "canonical_inspection_order",
          nodes: [
            Node.new!(name: :zeta, action: EchoParamsAction),
            Node.new!(name: :alpha, action: EchoParamsAction)
          ],
          return: Ref.result(:zeta)
        )

      assert {:ok, workflow} = Flow.compile(flow)
      assert Enum.map(Flow.canonical_nodes(flow.nodes), & &1.name) == ["alpha", "zeta"]

      assert MapSet.new(Enum.map(Workflow.steps(workflow), & &1.name)) ==
               MapSet.new(["alpha", "zeta"])
    end

    test "keeps inspection and runtime workflow topology equal" do
      flow = diamond_flow()

      assert {:ok, inspection} = Flow.compile(flow)
      assert {:ok, runtime} = Compiler.runtime_workflow(flow, %{value: 3}, %{})

      for workflow <- [inspection, runtime] do
        assert root_child?(workflow, "a")
        assert connects?(workflow, :a, :b)
        assert connects?(workflow, :a, :c)
        assert join_feeds?(workflow, ["b", "c"], "d")
      end
    end

    test "does not emit node telemetry during inspection" do
      event = [:jido, :flow, :node, :start]
      handler_id = {__MODULE__, self(), make_ref()}
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          event,
          fn event, _measurements, metadata, pid -> send(pid, {event, metadata}) end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, workflow} = Flow.compile(one_step_flow())
      Workflow.react_until_satisfied(workflow, %{})

      refute_receive {^event, %{flow: "one_step"}}
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
      assert Workflow.results(final_workflow, ["after_bad"]) == %{"after_bad" => nil}
      refute_receive {:after_bad, _state}
    end
  end

  describe "Reduce runtime" do
    test "folds a normal list in source order with stable Reduce-local item IDs" do
      flow =
        reduce_flow(
          "reduce_order",
          Ref.value([3, 1, 2]),
          Ref.value(%{values: [], indexes: []}),
          %{
            accumulator: Ref.accumulator(),
            item: Ref.item(),
            index: Ref.item_index(),
            item_id: Ref.item_id()
          }
        )

      assert {:ok, %{values: [3, 1, 2], indexes: [0, 1, 2]}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      calls =
        for _ <- 1..3 do
          assert_receive {ReduceProbeAction, :called, index, item_id, item, accumulator}
          {index, item_id, item, accumulator}
        end

      assert Enum.map(calls, &elem(&1, 0)) == [0, 1, 2]
      assert Enum.map(calls, &elem(&1, 2)) == [3, 1, 2]

      expected_ids =
        for index <- 0..2,
            do:
              Identity.item_uuid(
                Identity.semantic_digest(flow),
                "reduced",
                index
              )

      assert Enum.map(calls, &elem(&1, 1)) == expected_ids
      assert Enum.map(calls, fn {_index, _id, _item, acc} -> acc.values end) == [[], [3], [3, 1]]
    end

    test "returns a valid initial unchanged for an empty collection and does not call the target" do
      initial = Output.raw(%{values: []}, meta: %{source: :initial})

      flow =
        reduce_flow("empty_reduce", Ref.value([]), Ref.value(initial), %{
          accumulator: Ref.accumulator(),
          item: Ref.item(),
          index: Ref.item_index(),
          item_id: Ref.item_id()
        })

      assert {:ok, ^initial} = Compiler.run(flow, %{}, %{test_pid: self()})
      refute_receive {ReduceProbeAction, :called, _, _, _, _}
    end

    test "rejects a non-list collection before it validates the initial value" do
      flow =
        reduce_flow(
          "reduce_error_order",
          Ref.value(%{not: :a_list}),
          Ref.value(:invalid_initial),
          %{}
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "reduce collection must resolve to a proper list"

      assert details == %{
               phase: :reduce_collection,
               node: "reduced",
               reason: :not_a_proper_list,
               value_type: :map,
               retry: false
             }
    end

    test "rejects an invalid initial before the first reducer invocation" do
      flow =
        reduce_flow("invalid_reduce_initial", Ref.value([1]), Ref.value(0), %{
          accumulator: Ref.accumulator(),
          item: Ref.item(),
          index: Ref.item_index(),
          item_id: Ref.item_id()
        })

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      assert message == "reduce initial value must be a map or Jido.Action.Output"

      assert details == %{
               phase: :reduce_initial,
               node: "reduced",
               reason: :output_envelope_required,
               value_type: :number,
               retry: false
             }

      refute_receive {ReduceProbeAction, :called, _, _, _, _}
    end

    test "uses each Action output as the next accumulator and preserves non-associative order" do
      flow =
        reduce_flow(
          "reduce_subtract",
          Ref.value([3, 2, 1]),
          Ref.value(%{value: 10}),
          %{
            accumulator: Ref.accumulator(),
            item: Ref.item(),
            index: Ref.item_index(),
            item_id: Ref.item_id(),
            outcome: Ref.value(:subtract)
          }
        )

      assert {:ok, %{value: 4}} = Compiler.run(flow, %{}, %{test_pid: self()})

      for index <- 0..2 do
        assert_receive {ReduceProbeAction, :called, ^index, _item_id, _item, _accumulator}
      end
    end

    test "runs each reducer Action validation boundary exactly once per item" do
      flow =
        reduce_flow(
          "reduce_action_once",
          Ref.value([:first, :second]),
          Ref.value(%{}),
          %{
            test_pid: Ref.context(:test_pid),
            item: Ref.item(),
            index: Ref.item_index()
          },
          CountedReduceAction
        )

      assert {:ok, %{value: :second}} = Compiler.run(flow, %{}, %{test_pid: self()})

      for index <- 0..1 do
        assert_receive {CountedReduceAction, :input, ^index}
        assert_receive {CountedReduceAction, :run, ^index}
        assert_receive {CountedReduceAction, :output, ^index}
      end

      refute_receive {CountedReduceAction, _phase, _index}
    end

    test "tags reducer input rejection and stops the fold before later items" do
      items = [
        %{value: :first, reject: false},
        %{value: :second, reject: true},
        %{value: :third, reject: false}
      ]

      flow =
        reduce_flow(
          "reduce_rejected_input",
          Ref.value(items),
          Ref.value(%{values: []}),
          %{
            test_pid: Ref.context(:test_pid),
            accumulator: Ref.accumulator(),
            item: Ref.item(:value),
            index: Ref.item_index(),
            reject: Ref.item(:reject)
          },
          RejectingParamsAction
        )

      assert {:error, %ExecutionFailureError{message: "rejected_params", details: error_details}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      assert error_details.phase == :reduce_target_input
      assert error_details.node == "reduced"
      assert error_details.target == RejectingParamsAction
      assert error_details.item_index == 1
      assert is_binary(error_details.item_id)
      assert error_details.reason == :rejected_params

      assert_receive {RejectingParamsAction, :input, 0}
      assert_receive {RejectingParamsAction, :run, 0}
      assert_receive {RejectingParamsAction, :input, 1}
      refute_receive {RejectingParamsAction, :run, 1}
      refute_receive {RejectingParamsAction, :input, 2}
      refute_receive {RejectingParamsAction, :run, 2}
    end

    test "supports full and selected Output accumulators" do
      initial = Output.raw(%{values: []}, meta: %{source: :initial})

      output_flow =
        reduce_flow("reduce_output_accumulator", Ref.value([1, 2]), Ref.value(initial), %{
          accumulator: Ref.accumulator(),
          item: Ref.item(),
          index: Ref.item_index(),
          item_id: Ref.item_id(),
          outcome: Ref.value(:output)
        })

      assert {:ok, %Output{value: %{values: [1, 2]}, meta: %{source: :reduce}}} =
               Compiler.run(output_flow, %{}, %{})

      selected_flow =
        reduce_flow("reduce_selected_accumulator", Ref.value([3]), Ref.value(initial), %{
          accumulator: Ref.accumulator(:value),
          item: Ref.item(),
          index: Ref.item_index(),
          item_id: Ref.item_id()
        })

      assert {:ok, %{values: [3], indexes: [0]}} = Compiler.run(selected_flow, %{}, %{})
    end

    test "stops on the first reducer error and adds Reduce ownership details" do
      flow =
        reduce_flow(
          "reduce_target_error",
          Ref.value([
            %{value: :first, outcome: :map},
            %{value: :second, outcome: {:error, "second failed"}},
            %{value: :third, outcome: :map}
          ]),
          Ref.value(%{values: [], indexes: []}),
          %{
            accumulator: Ref.accumulator(),
            item: Ref.item(:value),
            index: Ref.item_index(),
            item_id: Ref.item_id(),
            outcome: Ref.item(:outcome)
          }
        )

      assert {:error, %ExecutionFailureError{message: "second failed", details: details}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      assert details.phase == :reduce_target_execution
      assert details.node == "reduced"
      assert details.target == ReduceProbeAction
      assert details.item_index == 1
      assert is_binary(details.item_id)

      assert_receive {ReduceProbeAction, :called, 0, _, :first, _}
      assert_receive {ReduceProbeAction, :called, 1, _, :second, _}
      refute_receive {ReduceProbeAction, :called, 2, _, :third, _}
    end

    test "rejects a scalar reducer output with the Reduce output phase" do
      flow =
        reduce_flow("reduce_scalar_output", Ref.value([1]), Ref.value(%{}), %{
          accumulator: Ref.accumulator(),
          item: Ref.item(),
          index: Ref.item_index(),
          item_id: Ref.item_id(),
          outcome: Ref.value(:scalar)
        })

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "action returned a value that requires an output envelope"
      assert details.phase == :reduce_target_output
      assert details.node == "reduced"
      assert details.target == ReduceProbeAction
      assert details.item_index == 0
    end

    test "consumes a direct Map aggregate in source order and reuses Map item IDs" do
      flow = map_reduce_runtime_flow(:fail_fast, Ref.result(:mapped))

      assert {:ok, %{values: [:zero, :one], indexes: [0, 1]}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      expected_ids =
        for index <- 0..1,
            do:
              Identity.item_uuid(
                Identity.semantic_digest(flow),
                "mapped",
                index
              )

      reduce_calls =
        for index <- 0..1 do
          assert_receive {ReduceProbeAction, :called, ^index, item_id, item, _accumulator}
          {item_id, item}
        end

      assert Enum.map(reduce_calls, &elem(&1, 0)) == expected_ids
      assert Enum.map(reduce_calls, &elem(&1, 1)) == [:zero, :one]
    end

    test "refuses collected direct Map errors before the first reducer call" do
      flow = map_reduce_runtime_flow(:collect_errors, Ref.result(:mapped), :with_error)

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      assert message == "reduce cannot consume a Map result with errors"

      assert details == %{
               phase: :reduce_collection,
               node: "reduced",
               reason: :map_errors_present,
               error_indices: [1],
               retry: false
             }

      refute_receive {ReduceProbeAction, :called, _, _, _, _}
    end

    test "rejects malformed direct Map aggregates before reducer input resolution" do
      flow = map_reduce_runtime_flow(:fail_fast, Ref.result(:mapped))

      assert {:ok, workflow, _nodes} =
               Compiler.runtime_workflow_validated(flow, %{}, %{test_pid: self()})

      reduce_step = Workflow.get_component(workflow, "reduced")

      valid_result = %{
        item_id: "123e4567-e89b-82d3-a456-426614174000",
        index: 0,
        output: %{value: :ok}
      }

      malformed = [
        %{kind: :jido_flow_map_result, results: [valid_result], errors: [], extra: true},
        %{kind: :jido_flow_map_result, results: [valid_result | :improper], errors: []},
        %{
          kind: :jido_flow_map_result,
          results: [valid_result, %{valid_result | item_id: "second", index: 0}],
          errors: []
        },
        %{
          kind: :jido_flow_map_result,
          results: [%{valid_result | item_id: :not_an_id}],
          errors: []
        }
      ]

      for aggregate <- malformed do
        node_error =
          assert_raise NodeError, fn ->
            reduce_step.work.(aggregate)
          end

        assert %ExecutionFailureError{message: message, details: details} = node_error.error
        assert message == "reduce received an invalid Map result"
        assert details.phase == :reduce_collection
        assert details.reason == :invalid_map_result
        assert details.retry == false
        assert is_list(details.path)
        refute_receive {ReduceProbeAction, :called, _, _, _, _}
      end
    end

    test "treats a projected Map results list as explicit partial success with Reduce-local IDs" do
      flow =
        map_reduce_runtime_flow(
          :collect_errors,
          Ref.result(:mapped, [:results]),
          :with_error,
          Ref.item(:output)
        )

      assert {:ok, %{values: [%{index: 0, value: :zero}], indexes: [0]}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      assert_receive {ReduceProbeAction, :called, 0, item_id, %{index: 0, value: :zero}, _}

      assert item_id ==
               Identity.item_uuid(
                 Identity.semantic_digest(flow),
                 "reduced",
                 0
               )
    end

    test "does not classify look-alike user data as a direct Map handoff" do
      look_alike = %{kind: :jido_flow_map_result, results: [], errors: []}
      flow = reduce_flow("look_alike_map_result", Ref.value(look_alike), Ref.value(%{}), %{})

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "reduce collection must resolve to a proper list"
      assert details.reason == :not_a_proper_list
      assert details.value_type == :map
    end
  end

  describe "Map runtime" do
    test "resolves one proper list into the exact ordered aggregate with scoped refs" do
      flow =
        map_flow(
          "map_serial",
          Ref.input(:items),
          RecorderAction,
          %{
            item: Ref.item(),
            index: Ref.item_index(),
            item_id: Ref.item_id()
          }
        )

      assert {:ok, %{kind: :jido_flow_map_result, results: results, errors: []}} =
               Compiler.run(flow, %{items: [%{value: 3}, %{value: 1}]}, %{test_pid: self()})

      assert Enum.map(results, & &1.index) == [0, 1]
      assert Enum.map(results, & &1.output.item.value) == [3, 1]
      assert Enum.map(results, & &1.output.index) == [0, 1]
      assert Enum.map(results, & &1.item_id) == Enum.map(results, & &1.output.item_id)
      assert Enum.all?(results, &is_binary(&1.item_id))

      assert_receive {RecorderAction, %{index: 0}}
      assert_receive {RecorderAction, %{index: 1}}
    end

    test "returns the exact empty aggregate and invokes no target" do
      flow = map_flow("map_empty", Ref.value([]), RecorderAction, Ref.item())

      assert Compiler.run(flow, %{}, %{test_pid: self()}) ==
               {:ok, %{kind: :jido_flow_map_result, results: [], errors: []}}

      refute_receive {RecorderAction, _params}
    end

    test "rejects improper lists and arbitrary Enumerables without enumerating them" do
      for collection <- [nil, [1 | 2], 1..3, Stream.map(1..3, & &1)] do
        flow = map_flow("map_invalid_collection", Ref.input(:items), RecorderAction, %{})

        assert {:error,
                %ExecutionFailureError{
                  message: "map collection must resolve to a proper list",
                  details: details
                }} = Compiler.run(flow, %{items: collection}, %{test_pid: self()})

        assert details == %{
                 phase: :map_collection,
                 node: "mapped",
                 reason: :not_a_proper_list,
                 value_type: value_type(collection),
                 retry: false
               }
      end

      refute_receive {RecorderAction, _params}
    end

    test "accepts map, Output, and extras results and rejects a raw scalar" do
      extras = map_flow("map_extras", Ref.value([2]), ExtrasAction, %{value: Ref.item()})

      assert {:ok, %{results: [%{output: %{value: 2}}], errors: []}} =
               Compiler.run(extras, %{}, %{})

      envelope =
        map_flow("map_envelope", Ref.value([3]), OutputEnvelopeAction, %{value: Ref.item()})

      assert {:ok, %{results: [%{output: %Output{value: %{value: 3}}}], errors: []}} =
               Compiler.run(envelope, %{}, %{})

      scalar = map_flow("map_scalar", Ref.value([4]), RawOutputAction, %{value: Ref.item()})

      assert {:error,
              %ExecutionFailureError{
                message: "action returned a value that requires an output envelope",
                details: details
              }} = Compiler.run(scalar, %{}, %{})

      assert details.phase == :map_target_output
      assert details.node == "mapped"
      assert details.target == RawOutputAction
      assert details.item_index == 0
      assert is_binary(details.item_id)
    end

    test "validates input, invokes, and validates output exactly once for each started item" do
      flow =
        map_flow(
          "map_exactly_once",
          Ref.value([:first, :second]),
          CountedMapAction,
          %{test_pid: Ref.context(:test_pid), index: Ref.item_index()}
        )

      assert {:ok, %{results: [_, _], errors: []}} =
               Compiler.run(flow, %{}, %{test_pid: self()})

      for index <- 0..1 do
        assert_receive {CountedMapAction, :input, ^index}
        assert_receive {CountedMapAction, :run, ^index}
        assert_receive {CountedMapAction, :output, ^index}
        refute_receive {CountedMapAction, _phase, ^index}
      end
    end

    test "tags Map input rejection and applies each error mode" do
      items = [
        %{value: :first, reject: true},
        %{value: :second, reject: false}
      ]

      input = %{
        test_pid: Ref.context(:test_pid),
        index: Ref.item_index(),
        value: Ref.item(:value),
        reject: Ref.item(:reject)
      }

      fail_fast =
        map_flow(
          "map_rejected_input_fail_fast",
          Ref.value(items),
          RejectingParamsAction,
          input
        )

      assert {:error,
              %ExecutionFailureError{message: "rejected_params", details: fail_fast_details}} =
               Compiler.run(fail_fast, %{}, %{test_pid: self()})

      assert fail_fast_details.phase == :map_target_input
      assert fail_fast_details.node == "mapped"
      assert fail_fast_details.target == RejectingParamsAction
      assert fail_fast_details.item_index == 0
      assert is_binary(fail_fast_details.item_id)
      assert fail_fast_details.reason == :rejected_params

      assert_receive {RejectingParamsAction, :input, 0}
      refute_receive {RejectingParamsAction, :run, 0}
      refute_receive {RejectingParamsAction, :input, 1}

      collect_errors =
        map_flow(
          "map_rejected_input_collect_errors",
          Ref.value(items),
          RejectingParamsAction,
          input,
          on_error: :collect_errors
        )

      assert {:ok,
              %{
                results: [%{index: 1}],
                errors: [
                  %{
                    index: 0,
                    item_id: item_id,
                    error: %ExecutionFailureError{
                      message: "rejected_params",
                      details: collect_details
                    }
                  }
                ]
              }} = Compiler.run(collect_errors, %{}, %{test_pid: self()})

      assert collect_details.phase == :map_target_input
      assert collect_details.node == "mapped"
      assert collect_details.target == RejectingParamsAction
      assert collect_details.item_index == 0
      assert collect_details.item_id == item_id
      assert collect_details.reason == :rejected_params

      assert_receive {RejectingParamsAction, :input, 0}
      assert_receive {RejectingParamsAction, :input, 1}
      assert_receive {RejectingParamsAction, :run, 1}
      refute_receive {RejectingParamsAction, :run, 0}
    end

    test "uses serial fail-fast and ordered collect-errors semantics" do
      input = %{
        test_pid: Ref.context(:test_pid),
        index: Ref.item_index(),
        value: Ref.item(:value),
        outcome: Ref.item(:outcome)
      }

      items = [
        %{value: :zero, outcome: :ok},
        %{value: :one, outcome: {:error, "one failed"}},
        %{value: :two, outcome: :ok}
      ]

      fail_fast = map_flow("map_fail_fast", Ref.value(items), MapProbeAction, input)

      assert {:error, %ExecutionFailureError{message: "one failed", details: fail_details}} =
               Compiler.run(fail_fast, %{}, %{test_pid: self()})

      assert fail_details.phase == :map_target_execution
      assert fail_details.item_index == 1
      assert fail_details.target == MapProbeAction
      assert_receive {MapProbeAction, :started, 0, _pid}
      assert_receive {MapProbeAction, :started, 1, _pid}
      refute_receive {MapProbeAction, :started, 2, _pid}

      collect =
        map_flow("map_collect", Ref.value(items), MapProbeAction, input,
          on_error: :collect_errors
        )

      assert {:ok, %{kind: :jido_flow_map_result, results: results, errors: errors}} =
               Compiler.run(collect, %{}, %{test_pid: self()})

      assert Enum.map(results, & &1.index) == [0, 2]
      assert Enum.map(errors, & &1.index) == [1]
      assert [%{error: %ExecutionFailureError{message: "one failed"}}] = errors
      assert_receive {MapProbeAction, :started, 0, _pid}
      assert_receive {MapProbeAction, :started, 1, _pid}
      assert_receive {MapProbeAction, :started, 2, _pid}
    end
  end

  describe "run/3" do
    test "rejects invalid runtime workflow input and non-list run options" do
      flow = one_step_flow()

      assert {:error, %InvalidInputError{message: "flow input and context must be maps"}} =
               Compiler.runtime_workflow(flow, [], %{})

      assert {:error, %InvalidInputError{message: "run options must be a keyword list"}} =
               Compiler.run(flow, %{}, %{}, :not_options)
    end

    test "node error messages include the normalized error message" do
      assert_raise NodeError, ~r/flow node "bad" failed: boom/, fn ->
        raise NodeError, node: "bad", error: %RuntimeError{message: "boom"}
      end
    end

    test "uses an empty context by default" do
      assert {:ok, 4} = Compiler.run(one_step_flow(), %{value: 3})
    end

    test "accepts runtime options during direct compiler execution" do
      assert {:ok, 4} = Compiler.run(one_step_flow(), %{value: 3}, %{}, async: true)
    end

    test "validates runtime options during direct compiler execution" do
      flow = one_step_flow()

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{}, timeout: 100)

      assert message =~ "unknown run option"
      assert details.option == :timeout

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{}, async: :yes)

      assert message =~ "async option must be a boolean"
      assert details.option == :async

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Compiler.run(flow, %{value: 3}, %{}, max_concurrency: 0)

      assert message =~ "max_concurrency option must be a positive integer"
      assert details.option == :max_concurrency
    end

    test "executes the compiled workflow and extracts the declared return" do
      assert {:ok, flow} = Jido.Flow.Builder.build(FlowFixtures.math_builder())
      assert {:ok, %{value: 8}} = Compiler.run(flow, %{value: 3}, %{})
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

    test "uses the normalized return expression for raw flows" do
      flow = %Flow{
        name: "raw_return_ref",
        description: nil,
        schema: [],
        output_schema: [],
        nodes: [
          Node.new!(
            name: :echo,
            action: EchoParamsAction,
            input: %{value: Ref.input(:value)}
          )
        ],
        return: %Ref{type: :result, node: :echo, path: [:value]},
        provenance: %{}
      }

      assert {:ok, 3} = Compiler.run(flow, %{value: 3}, %{})
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
      assert details.node == "broken"
      assert details.action == MissingRun
      assert details.reason == "missing run/2"
    end

    test "rejects list-valued raw leaf action results" do
      flow =
        Flow.new!(
          name: "raw_list_result",
          nodes: [
            Node.new!(
              name: :source,
              action: RawOutputAction,
              input: %{value: [Ref.value(:left), Ref.value(:right)]}
            )
          ],
          return: Ref.result(:source)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "action returned a value that requires an output envelope"
      assert details.phase == :step_output
      assert details.node == "source"
      assert details.action == RawOutputAction
      assert details.callback == :run
      assert details.output == [:left, :right]
    end

    test "rejects scalar values returned by a leaf output validator" do
      flow =
        Flow.new!(
          name: "scalar_validated_output",
          nodes: [
            Node.new!(name: :bad, action: InvalidValidatedOutputAction)
          ],
          return: Ref.result(:bad)
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(flow, %{}, %{})

      assert message == "action validator returned a value with an invalid shape"
      assert details.phase == :step_output
      assert details.node == "bad"
      assert details.action == InvalidValidatedOutputAction
      assert details.callback == :validate_output
      assert details.expected == :map_or_output_envelope
      assert details.result == 42
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

    test "drops action extras inside flows while direct execution preserves them" do
      flow =
        Flow.new!(
          name: "extras",
          nodes: [
            Node.new!(name: :extras, action: ExtrasAction, input: %{value: Ref.input(:value)})
          ],
          return: Ref.result(:extras, :value)
        )

      context = %{trace_id: "trace"}

      assert {:ok, %{value: 3}, ^context} = Jido.Exec.run(ExtrasAction, %{value: 3}, context)
      assert {:ok, 3} = Compiler.run(flow, %{value: 3}, context)
    end

    test "drops action extras from flow errors while keeping step metadata" do
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
      assert details.node == "bad"
      assert details.action == ErrorWithExtrasAction
      assert details.reason == :bad_with_extras
      refute Map.has_key?(details, :extras)
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

      assert {:ok, %{total: 42}} = Compiler.run(flow, input, %{})
    end

    test "executes shaped return expressions after the workflow settles" do
      flow =
        Flow.new!(
          name: "shaped_return",
          nodes: [
            Node.new!(
              name: :add_one,
              action: Add,
              input: %{value: Ref.input(:value), amount: Ref.value(1)}
            ),
            Node.new!(
              name: :double,
              action: Multiply,
              input: %{value: Ref.result(:add_one, :value), amount: Ref.value(2)}
            )
          ],
          return: %{
            sum: Ref.result(:add_one, :value),
            product: Ref.result(:double, :value),
            original: Ref.input(:value),
            trace_id: Ref.context(:trace_id),
            literal: "ok",
            nested: [Ref.result(:double, :value)]
          }
        )

      assert {:ok,
              %{
                sum: 4,
                product: 8,
                original: 3,
                trace_id: "trace-1",
                literal: "ok",
                nested: [8]
              }} = Compiler.run(flow, %{value: 3}, %{trace_id: "trace-1"})
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
            name: "echo",
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

      assert message =~ "node input contains invalid ref"
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
      assert details.node == "add_one"
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
      assert details.node == "invalid"
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
      assert details.node == "bad"
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
      assert details.node == "bad"
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
      assert details.node == "bad"
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
      assert details.node == "b"
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
      assert details.node == "bad"
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
      assert details.node == "bad"
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
      assert details.node == "throwing"
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
      assert details.node == "full"
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
      assert details.node == "bad_params"
      assert details.action == AtomValidationAction
      assert details.reason == :bad_params
    end
  end

  describe "Choice runtime" do
    test "runs the first matching option or the fallback as one result" do
      flow =
        Flow.new!(
          name: "choice_selects_one_target",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :matched,
                  condition: Condition.eq(Ref.input(:kind), Ref.value(:matched)),
                  action: EchoParamsAction,
                  input: %{selected: Ref.value(:option)}
                ]
              ],
              fallback: [action: EchoParamsAction, input: %{selected: Ref.value(:fallback)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{selected: :option}} = Compiler.run(flow, %{kind: :matched}, %{})
      assert {:ok, %{selected: :fallback}} = Compiler.run(flow, %{kind: :other}, %{})
    end

    test "uses authored option order and recursively short-circuits boolean conditions" do
      flow =
        Flow.new!(
          name: "choice_order_and_short_circuit",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :first,
                  condition:
                    Condition.all([
                      Condition.eq(Ref.input(:kind), Ref.value(:never)),
                      Condition.lt(Ref.value("invalid"), Ref.value(1))
                    ]),
                  action: EchoParamsAction,
                  input: %{selected: Ref.value(:first)}
                ],
                [
                  name: :second,
                  condition:
                    Condition.any([
                      Condition.not(Condition.eq(Ref.input(:kind), Ref.value(:never))),
                      Condition.lt(Ref.value("invalid"), Ref.value(1))
                    ]),
                  action: EchoParamsAction,
                  input: %{selected: Ref.value(:second)}
                ],
                [
                  name: :also_matched,
                  condition: Condition.lt(Ref.value("invalid"), Ref.value(1)),
                  action: EchoParamsAction,
                  input: %{selected: Ref.value(:third)}
                ]
              ],
              fallback: [action: EchoParamsAction, input: %{selected: Ref.value(:fallback)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{selected: :second}} = Compiler.run(flow, %{kind: :matched}, %{})
    end

    test "supports all comparison operators and nil for missing paths" do
      for {operator, input, expected} <- [
            {:eq, %{left: 1, right: 1.0}, :matched},
            {:neq, %{left: :one, right: :two}, :matched},
            {:lt, %{left: 1, right: 2}, :matched},
            {:lte, %{left: "a", right: "a"}, :matched},
            {:gt, %{left: "b", right: "a"}, :matched},
            {:gte, %{left: 2, right: 2}, :matched},
            {:in, %{left: :two, right: [:one, :two]}, :matched},
            {:eq, %{}, :matched}
          ] do
        {left, right} =
          if input == %{} do
            {Ref.input(:missing), Ref.context(:missing)}
          else
            {Ref.input(:left), Ref.input(:right)}
          end

        condition = Condition.new!(operator, [left, right])

        flow =
          choice_flow(
            "choice_#{operator}_#{System.unique_integer([:positive])}",
            [
              [
                name: :matched,
                condition: condition,
                action: EchoParamsAction,
                input: %{result: Ref.value(:matched)}
              ]
            ],
            action: EchoParamsAction,
            input: %{result: Ref.value(:fallback)}
          )

        assert {:ok, %{result: ^expected}} = Compiler.run(flow, input, %{})
      end
    end

    test "resolves input, context, prior result, and static operands in one condition" do
      flow =
        Flow.new!(
          name: "choice_all_operand_sources",
          nodes: [
            Node.new!(
              name: :source,
              action: EchoParamsAction,
              input: %{value: Ref.input(:value)}
            ),
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :matched,
                  condition:
                    Condition.all([
                      Condition.eq(Ref.input(:input_flag), Ref.value(true)),
                      Condition.eq(Ref.context(:context_flag), Ref.value(:ready)),
                      Condition.eq(Ref.result(:source, :value), Ref.value(3)),
                      Condition.eq(Ref.value(:static), Ref.value(:static))
                    ]),
                  action: EchoParamsAction,
                  input: %{selected: Ref.value(:matched)}
                ]
              ],
              fallback: [action: EchoParamsAction, input: %{selected: Ref.value(:fallback)}]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{selected: :matched}} =
               Compiler.run(flow, %{value: 3, input_flag: true}, %{context_flag: :ready})
    end

    test "returns a non-retryable execution error for invalid ordering and membership operands" do
      for {condition, input, operator, reason, left_type, right_type} <- [
            {Condition.lt(Ref.value("a"), Ref.value(1)), %{}, :lt, :invalid_ordering_operands,
             :binary, :number},
            {Condition.in(Ref.value(:item), Ref.value(:not_a_list)), %{}, :in,
             :invalid_membership_right_operand, :atom, :atom},
            {Condition.in(Ref.value(:item), Ref.input(:right)), %{right: [:item | :tail]}, :in,
             :invalid_membership_right_operand, :atom, :list}
          ] do
        flow =
          choice_flow(
            "choice_invalid_#{operator}",
            [[name: :bad, condition: condition, action: RecorderAction]],
            action: RecorderAction
          )

        assert {:error, %ExecutionFailureError{message: message, details: details} = error} =
                 Compiler.run(flow, input, %{test_pid: self()})

        assert message == "invalid choice condition operands"

        assert details == %{
                 phase: :choice_condition,
                 node: "route",
                 option: "bad",
                 operator: operator,
                 reason: reason,
                 left_type: left_type,
                 right_type: right_type,
                 retry: false
               }

        assert Jido.Action.Error.to_map(error).retryable? == false
        refute_receive {RecorderAction, _params}
      end
    end

    test "resolves only the selected target input while all graph predecessors still run" do
      flow =
        Flow.new!(
          name: "choice_lazy_target_input",
          nodes: [
            Node.new!(
              name: :upstream,
              action: RecorderAction,
              input: %{source: Ref.value(:upstream)}
            ),
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :skip,
                  condition: Condition.eq(Ref.value(false), Ref.value(true)),
                  action: RecorderAction,
                  input: %{source: Ref.result(:upstream, :source), selected: Ref.value(:skip)}
                ]
              ],
              fallback: [
                action: RecorderAction,
                input: %{selected: Ref.value(:fallback)}
              ]
            )
          ],
          return: Ref.result(:route)
        )

      assert {:ok, %{selected: :fallback}} = Compiler.run(flow, %{}, %{test_pid: self()})
      assert_receive {RecorderAction, %{source: :upstream}}
      assert_receive {RecorderAction, %{selected: :fallback}}
      refute_receive {RecorderAction, %{selected: :skip}}
    end

    test "passes the selected result to a downstream node and preserves output contracts" do
      flow =
        Flow.new!(
          name: "choice_downstream_result",
          nodes: [
            Choice.new!(
              name: :route,
              options: [
                [
                  name: :matched,
                  condition: Condition.eq(Ref.input(:kind), Ref.value(:matched)),
                  action: EchoParamsAction,
                  input: %{value: Ref.value(3)}
                ]
              ],
              fallback: [action: EchoParamsAction, input: %{value: Ref.value(4)}]
            ),
            Node.new!(
              name: :downstream,
              action: Add,
              input: %{value: Ref.result(:route, :value), amount: Ref.value(1)}
            )
          ],
          return: Ref.result(:downstream)
        )

      assert {:ok, %{value: 4}} = Compiler.run(flow, %{kind: :matched}, %{})
      assert {:ok, %{value: 5}} = Compiler.run(flow, %{kind: :other}, %{})

      scalar_flow =
        choice_flow(
          "choice_scalar_output",
          [
            [
              name: :matched,
              condition: Condition.eq(Ref.value(true), Ref.value(true)),
              action: RawOutputAction,
              input: %{value: Ref.value(3)}
            ]
          ],
          action: EchoParamsAction
        )

      assert {:error, %ExecutionFailureError{message: message, details: details}} =
               Compiler.run(scalar_flow, %{}, %{})

      assert message == "action returned a value that requires an output envelope"
      assert details.phase == :choice_target_output
      assert details.node == "route"
      assert details.option == "matched"
      assert details.target == RawOutputAction

      envelope_flow =
        choice_flow(
          "choice_output_envelope",
          [
            [
              name: :matched,
              condition: Condition.eq(Ref.value(true), Ref.value(true)),
              action: OutputEnvelopeAction,
              input: %{value: Ref.value(3)}
            ]
          ],
          action: EchoParamsAction
        )

      assert {:ok, %Output{kind: :raw, value: %{value: 3}, meta: %{source: :test}}} =
               Compiler.run(envelope_flow, %{}, %{})
    end

    test "adds Choice target metadata without changing the selected target error class or reason" do
      flow =
        choice_flow(
          "choice_error_metadata",
          [
            [
              name: :matched,
              condition: Condition.eq(Ref.value(true), Ref.value(true)),
              action: ErrorAction,
              input: %{error_type: Ref.value(:validation)}
            ]
          ],
          action: EchoParamsAction
        )

      assert {:error, %ExecutionFailureError{message: "Validation error", details: details}} =
               Compiler.run(flow, %{}, %{})

      assert details.reason == "Validation error"
      assert details.phase == :choice_target_execution
      assert details.node == "route"
      assert details.option == "matched"
      assert details.target == ErrorAction
    end

    test "emits one Choice node span with selected target metadata only at stop" do
      start_event = [:jido, :flow, :node, :start]
      stop_event = [:jido, :flow, :node, :stop]
      handler_id = {__MODULE__, self(), make_ref()}
      test_pid = self()

      for event <- [start_event, stop_event] do
        :ok =
          :telemetry.attach(
            {handler_id, event},
            event,
            fn event, _measurements, metadata, pid -> send(pid, {event, metadata}) end,
            test_pid
          )
      end

      on_exit(fn ->
        :telemetry.detach({handler_id, start_event})
        :telemetry.detach({handler_id, stop_event})
      end)

      flow =
        choice_flow(
          "choice_telemetry",
          [
            [
              name: :selected,
              condition: Condition.eq(Ref.value(true), Ref.value(true)),
              action: EchoParamsAction,
              input: %{value: Ref.value(3)}
            ],
            [
              name: :unselected,
              condition: Condition.eq(Ref.value(true), Ref.value(true)),
              action: RecorderAction
            ]
          ],
          action: RecorderAction
        )

      assert {:ok, %{value: 3}} = Compiler.run(flow, %{}, %{})

      assert_receive {^start_event,
                      %{flow: "choice_telemetry", node: "route", kind: :choice} = start}

      refute Map.has_key?(start, :option)
      refute Map.has_key?(start, :target)

      assert_receive {^stop_event,
                      %{
                        flow: "choice_telemetry",
                        node: "route",
                        kind: :choice,
                        status: :ok,
                        option: "selected",
                        target: EchoParamsAction
                      }}

      refute_receive {^start_event, %{flow: "choice_telemetry"}}
      refute_receive {^stop_event, %{flow: "choice_telemetry"}}
    end
  end

  defp choice_flow(name, options, fallback) do
    Flow.new!(
      name: name,
      nodes: [Choice.new!(name: :route, options: options, fallback: fallback)],
      return: Ref.result(:route)
    )
  end

  defp map_flow(name, collection, action, input, opts \\ []) do
    Flow.new!(
      name: name,
      nodes: [
        FlowMap.new!(
          name: :mapped,
          collection: collection,
          action: action,
          input: input,
          on_error: Keyword.get(opts, :on_error, :fail_fast)
        )
      ],
      return: Ref.result(:mapped)
    )
  end

  defp reduce_flow(name, collection, initial, input, action \\ ReduceProbeAction) do
    Flow.new!(
      name: name,
      nodes: [
        Reduce.new!(
          name: :reduced,
          collection: collection,
          initial: initial,
          action: action,
          input: input
        )
      ],
      return: Ref.result(:reduced)
    )
  end

  defp map_reduce_runtime_flow(
         on_error,
         reduce_collection,
         mode \\ :success,
         item_ref \\ Ref.item(:value)
       ) do
    items =
      case mode do
        :success ->
          [%{value: :zero, outcome: :ok}, %{value: :one, outcome: :ok}]

        :with_error ->
          [%{value: :zero, outcome: :ok}, %{value: :one, outcome: {:error, "map failed"}}]
      end

    Flow.new!(
      name: "map_reduce_runtime",
      nodes: [
        FlowMap.new!(
          name: :mapped,
          collection: Ref.value(items),
          action: MapProbeAction,
          input: %{
            test_pid: Ref.context(:test_pid),
            value: Ref.item(:value),
            outcome: Ref.item(:outcome),
            index: Ref.item_index()
          },
          on_error: on_error
        ),
        Reduce.new!(
          name: :reduced,
          collection: reduce_collection,
          initial: Ref.value(%{values: [], indexes: []}),
          action: ReduceProbeAction,
          input: %{
            accumulator: Ref.accumulator(),
            item: item_ref,
            index: Ref.item_index(),
            item_id: Ref.item_id()
          }
        )
      ],
      return: Ref.result(:reduced)
    )
  end

  defp value_type(nil), do: nil
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_number(value), do: :number
  defp value_type(value) when is_atom(value), do: :atom
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(_value), do: :other

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

  defp mixed_choice_flow(order) do
    options = %{
      first: [
        name: :first,
        condition: Condition.eq(Ref.result(:source, :value), 1),
        action: Add
      ],
      second: [
        name: :second,
        condition: Condition.eq(Ref.input(:kind), :second),
        action: Multiply
      ]
    }

    Flow.new!(
      name: "mixed_choice_steps",
      nodes: [
        Node.new!(name: :source, action: EchoParamsAction, input: %{value: Ref.input(:value)}),
        Choice.new!(
          name: :route,
          options: Enum.map(order, &Map.fetch!(options, &1)),
          fallback: [action: Add]
        )
      ],
      return: Ref.result(:route)
    )
  end

  defp root_child?(workflow, node_name) do
    node = workflow_component(workflow, node_name)

    Enum.any?(Multigraph.edges(workflow.graph, by: :flow), fn edge ->
      match?(%Runic.Workflow.Root{}, edge.v1) and edge.v2 == node
    end)
  end

  defp connects?(workflow, parent_name, child_name) do
    parent = workflow_component(workflow, parent_name)
    child = workflow_component(workflow, child_name)

    edge?(workflow, parent, child, :connects_to)
  end

  defp join_feeds?(workflow, parent_names, child_name) do
    parents = Enum.map(parent_names, &workflow_component(workflow, &1))
    child = workflow_component(workflow, child_name)

    workflow.graph
    |> Multigraph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Join{}, &1))
    |> Enum.any?(fn join ->
      Enum.all?(parents, &edge?(workflow, &1, join, :flow)) and
        edge?(workflow, join, child, :flow)
    end)
  end

  defp workflow_component(workflow, name) when is_atom(name) do
    Workflow.get_component(workflow, Atom.to_string(name))
  end

  defp workflow_component(workflow, name), do: Workflow.get_component(workflow, name)

  defp edge?(workflow, from, to, label) do
    Enum.any?(Multigraph.edges(workflow.graph, by: label), fn edge ->
      edge.v1 == from and edge.v2 == to
    end)
  end
end
