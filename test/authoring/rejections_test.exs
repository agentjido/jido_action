Code.require_file("support/components.ex", __DIR__)
Code.require_file("support/hostile.ex", __DIR__)

defmodule JidoActionTest.Authoring.RejectionsTest do
  use ExUnit.Case, async: false
  @moduletag :authoring

  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Choice, Dispatch, Iterate, Ref, Reduce, Step, Subflow}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Authoring.Components
  alias JidoActionTest.Authoring.Hostile

  test "Action-only component slots reject a Flow target at executable validation" do
    child = Components.Child
    option = Choice.Option.new!(name: "selected", condition: true, action: child)
    fallback = Choice.Fallback.new!(action: Components.Echo)
    state = Components.IterateRepeat.flow().components |> hd() |> Map.fetch!(:state)

    components = [
      {FlowMap.new!(name: "node", collection: [], action: child), :action},
      {Reduce.new!(name: "node", collection: [], initial: %{}, action: child), :action},
      {Iterate.new!(
         name: "node",
         state: state,
         action: child,
         completion: true,
         max_iterations: 1
       ), :action},
      {Choice.new!(name: "node", options: [option], fallback: fallback), "selected"},
      {Choice.new!(
         name: "node",
         options: [Choice.Option.new!(name: "selected", condition: true, action: Components.Echo)],
         fallback: Choice.Fallback.new!(action: child)
       ), :fallback},
      {Dispatch.new!(name: "node", decision: child, expander: Components.Expand), :decision},
      {Dispatch.new!(name: "node", decision: Components.Decide, expander: child), :expander}
    ]

    for {component, field} <- components do
      flow = Flow.new!(name: "wrong_target", components: [component], output: Ref.result("node"))
      assert {:error, error} = Flow.validate_executable(flow)
      assert error.details.component == "node"
      assert error.details.field == field
      assert error.details.expected == :action
      assert error.details.actual == :flow
      assert {:error, _} = Exec.run(flow)
    end
  end

  test "Map, Reduce, and Iterate reject references outside each local scope" do
    assert {:error, map_error} =
             FlowMap.new(
               name: "map",
               collection: Ref.item(),
               action: Components.MapItem
             )

    assert map_error.details.ref_type == :item
    assert map_error.details.scope == :map_collection

    assert {:error, map_params_error} =
             FlowMap.new(
               name: "map",
               collection: [],
               action: Components.MapItem,
               params: %{value: Ref.accumulator()}
             )

    assert map_params_error.details.ref_type == :accumulator
    assert map_params_error.details.scope == :map_params

    assert {:error, reduce_error} =
             Reduce.new(
               name: "reduce",
               collection: [],
               initial: Ref.accumulator(),
               action: Components.Fold
             )

    assert reduce_error.details.ref_type == :accumulator
    assert reduce_error.details.scope == :reduce_initial

    assert {:error, iterate_error} =
             Iterate.State.new(initial: Ref.state(:count), update: %{})

    assert iterate_error.details.ref_type == :state
    assert iterate_error.details.scope == :iterate_initial
  end

  test "Reduce rejects an invalid initial value before running its body" do
    assert {:error, error} =
             Exec.run(
               Hostile.ReduceInitial,
               %{items: [1, 2], initial: :not_a_map},
               %{observer: self()}
             )

    assert error.message == "reduce initial value must be a map or Jido.Action.Output"
    assert error.details.phase == :reduce_initial
    assert error.details.node == "fold"
    refute_received {:fold, _, _}
  end

  test "Choice rejects missing fallback and non-Boolean direct conditions" do
    valid_option = Choice.Option.new!(name: "ready", condition: true, action: Hostile.Watch)

    assert {:error, missing} = Choice.new(name: "route", options: [valid_option])
    assert missing.message =~ "fallback"

    assert {:error, condition} =
             Choice.Option.new(name: "ready", condition: :truthy, action: Hostile.Watch)

    assert condition.message =~ "condition"
    refute_received {:hostile_action, _}
  end

  test "a non-Boolean Choice condition never calls either target" do
    assert {:error, error} =
             Exec.run(Hostile.ChoiceNonBoolean, %{condition: "yes"}, %{observer: self()})

    assert error.details.node == "route"
    assert error.details.phase == :choice_condition
    assert error.details.reason == :invalid_boolean_operand
    refute_received {:hostile_action, _}

    assert Exec.run(Hostile.ChoiceNonBoolean, %{condition: true}) ==
             {:ok, %{branch: :selected}}

    assert Exec.run(Hostile.ChoiceNonBoolean, %{condition: false}) ==
             {:ok, %{branch: :fallback}}
  end

  test "Iterate validates initial and replacement State before another body call" do
    assert {:error, initial_error} =
             Exec.run(Hostile.IterateInitial, %{seed: "wrong type"}, %{observer: self()})

    assert initial_error.details.node == "counter"
    assert initial_error.details.phase == :iterate_state_initial
    refute_received {:hostile_action, _}

    assert {:error, replacement_error} =
             Exec.run(Hostile.IterateReplacement, %{}, %{observer: self()})

    assert replacement_error.details.node == "counter"
    assert replacement_error.details.phase == :iterate_state_update
    assert_receive :bad_state_called
    refute_received :bad_state_called
  end

  test "Iterate rejects a non-Boolean completion value before its body" do
    assert {:error, error} =
             Exec.run(Hostile.IterateCondition, %{condition: "truthy"}, %{observer: self()})

    assert error.details.node == "counter"
    refute_received {:hostile_action, _}
  end

  test "Iterate source rejects a missing while bound and a Flow body target" do
    for {suffix, action, bound, message} <- [
          {"MissingBound", Hostile.Watch, "", "iterate max_iterations must be an integer"},
          {"FlowTarget", Hostile.ValidatedFinalFlow, "max_iterations 2", "wrong executable kind"}
        ] do
      source = """
      defmodule JidoActionTest.Authoring.Hostile.#{suffix} do
        use Jido.Flow, name: "authoring_iterate_#{suffix}"
        flow do
          iterate "counter" do
            state Zoi.object(%{count: Zoi.integer()}), initial: %{count: 0}
            action #{inspect(action)}
            params %{count: state(:count)}
            update %{count: body_result(:count)}
            while state(:count) < 1
            #{bound}
          end
          output result("counter")
        end
      end
      """

      file = "authoring_iterate_#{suffix}.ex"
      error = assert_raise CompileError, fn -> Code.compile_string(source, file) end
      assert error.file == file
      assert Exception.message(error) =~ message
    end
  end

  test "Dispatch rejects a second sink, a second Dispatch, and a partial output" do
    dispatch = Components.DispatchFlow.flow().components |> hd()
    tail = Step.new!(name: "tail", action: Components.Echo, needs: ["route"])

    second =
      Dispatch.new!(name: "again", decision: Components.Decide, expander: Components.Expand)

    cases = [
      {[dispatch, tail], Ref.result("tail"), "Dispatch must be the final component"},
      {[dispatch, second], Ref.result("route"), "only one Dispatch"},
      {[dispatch], %{value: Ref.result("route", :value)}, "complete Dispatch result"}
    ]

    for {components, output, message} <- cases do
      assert {:error, error} =
               Flow.new(name: "invalid_dispatch", components: components, output: output)

      assert error.message =~ message
    end

    parent =
      Flow.new!(
        name: "dispatch_parent",
        components: [Subflow.new!(name: "child", flow: Components.DispatchFlow)],
        output: Ref.result("child")
      )

    assert {:error, error} = Flow.validate_executable(parent)
    assert error.message =~ "cannot be used as a Subflow"
  end

  test "a wrong-kind source declaration reports its own source file and line" do
    source = """
    defmodule JidoActionTest.Authoring.Hostile.WrongKindSource do
      use Jido.Flow, name: "wrong_kind_source"
      flow do
        map "items", collection: input(:items), action: JidoActionTest.Authoring.Components.Child, params: %{}
        output %{items: result("items")}
      end
    end
    """

    error =
      assert_raise CompileError, fn ->
        Code.compile_string(source, "authoring_wrong_kind_source.ex")
      end

    assert error.file == "authoring_wrong_kind_source.ex"
    assert error.line == 4
    assert Exception.message(error) =~ "wrong executable kind"
  end

  test "a stale step-wise authored Flow cannot repeat Action work" do
    flow =
      Flow.new!(
        name: "stale_authoring",
        components: [
          Step.new!(
            name: "observed",
            action: Hostile.Watch,
            params: %{value: Ref.input(:value)}
          )
        ],
        output: Ref.result("observed")
      )

    assert {:ok, stale} = Exec.start(flow, %{value: 7}, %{observer: self()})
    assert {:ok, _work, current} = Exec.step(stale)
    assert_receive {:hostile_action, %{value: 7}}
    assert Exec.result(current) == {:ok, %{value: 7}}

    assert {:error, error} = Exec.continue(stale)
    assert error.details.reason == :stale_revision
    refute_received {:hostile_action, _}
  end

  test "only references and needs order a diamond declared in reverse source order" do
    flow = Hostile.Diamond.flow()
    assert Enum.map(flow.components, & &1.name) == ["sink", "left", "right", "root"]

    assert {:ok, dependencies} = Flow.dependencies(flow)
    assert dependencies["root"].effective == []
    assert dependencies["left"] == %{references: [], needs: ["root"], effective: ["root"]}
    assert dependencies["right"] == %{references: ["root"], needs: [], effective: ["root"]}

    assert dependencies["sink"] == %{
             references: ["right"],
             needs: ["left"],
             effective: ["left", "right"]
           }

    assert Exec.run(Hostile.Diamond, %{value: 8}, %{observer: self()}, max_concurrency: 2) ==
             {:ok, %{value: 8}}

    assert_receive {:hostile_action, %{id: "root", value: 8}}
    assert_receive {:hostile_action, %{id: first, value: 8}}
    assert_receive {:hostile_action, %{id: second, value: 8}}
    assert MapSet.new([first, second]) == MapSet.new(["left", "right"])
    assert_receive {:hostile_action, %{id: "sink", value: 8}}
    refute_received {:hostile_action, _}
  end

  test "Dispatch and ordinary Steps reject a decision or Step continuation" do
    dispatch =
      Dispatch.new!(
        name: "route",
        decision: Hostile.Continues,
        expander: Hostile.Watch,
        params: %{value: Ref.input(:value)}
      )

    dispatch_flow =
      Flow.new!(name: "illegal_decision", components: [dispatch], output: Ref.result("route"))

    step_flow =
      Flow.new!(
        name: "illegal_step",
        components: [
          Step.new!(
            name: "early",
            action: Hostile.Continues,
            params: %{value: Ref.input(:value)}
          )
        ],
        output: Ref.result("early")
      )

    for flow <- [dispatch_flow, step_flow] do
      assert {:error, error} = Exec.run(flow, %{value: 1}, %{observer: self()})
      assert error.message == "action continuation is not allowed from this Flow position"
      assert_receive :attempted_continuation
      refute_received {:hostile_action, _}
    end
  end

  test "Dispatch rejects step-wise use and Subflow use before target work" do
    dispatch =
      Dispatch.new!(name: "route", decision: Hostile.Watch, expander: Hostile.Watch)

    child =
      Flow.new!(name: "watched_dispatch", components: [dispatch], output: Ref.result("route"))

    assert {:error, step_error} = Exec.start(child, %{}, %{observer: self()})
    assert step_error.message == "step-wise execution does not support Dispatch"

    # Subflow validation uses a source module, not a copied artifact.
    assert {:error, subflow_error} =
             Exec.run(
               Flow.new!(
                 name: "dispatch_parent",
                 components: [Subflow.new!(name: "child", flow: Components.DispatchFlow)],
                 output: Ref.result("child")
               ),
               %{},
               %{observer: self()}
             )

    assert subflow_error.message =~ "cannot be used as a Subflow"
    refute_received {:hostile_action, _}
  end

  test "Dispatch continuation uses final Action or Flow output validation" do
    dispatch = Components.DispatchFlow.flow().components |> hd()

    strict_root =
      Flow.new!(
        name: "strict_dispatch_root",
        components: [dispatch],
        output: Ref.result("route"),
        output_schema: Zoi.object(%{value: Zoi.string()})
      )

    context = %{label: "shared"}

    assert {:error, _root_schema_error} =
             Exec.run(strict_root, %{mode: :finish, value: 5, target: nil}, context)

    for target <- [Hostile.ValidatedFinal, Hostile.ValidatedFinalFlow] do
      input = %{mode: :continue, value: 5, target: target}
      assert Exec.run(strict_root, input, context) == {:ok, %{value: 5, label: "shared"}}

      assert {:error, direct_error} = Exec.run(target, %{value: "bad"}, context)

      assert {:error, continued_error} =
               Exec.run(strict_root, %{input | value: "bad"}, context)

      assert continued_error.__struct__ == direct_error.__struct__
      assert continued_error.message == direct_error.message
    end
  end

  test "a Dispatch continuation chain stops at its complete-call limit" do
    assert {:error, error} =
             Exec.run(
               Components.DispatchFlow,
               %{mode: :continue, value: 5, target: Hostile.Loop},
               %{observer: self()},
               max_continuations: 2
             )

    assert error.message == "continuation limit exceeded"
    assert error.details.count == 3
    assert error.details.max_continuations == 2
  end
end
