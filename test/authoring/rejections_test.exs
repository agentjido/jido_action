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
end
