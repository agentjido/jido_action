defmodule JidoTest.FlowSwitchTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Flow.Switch
  alias JidoTest.TestActions.FlowFunctions
  alias JidoTest.TestActions.{Add, Fail, NoParamsAction}
  alias Runic.Workflow

  def premium_tier?(:premium), do: true
  def premium_tier?(_tier), do: false

  test "compact switch can pass through the selected input value" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{name: :premium, predicate: {FlowFunctions, :premium?}, then: :premium}
        ],
        default: :standard,
        return?: false
      })

    order = %{tier: :premium, value: 3}

    assert {:ok, ^order} = Switch.select(switch, %{order: order})
  end

  test "compact switch can return map literal targets and defaults" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{name: :premium, predicate: {FlowFunctions, :premium?}, then: %{route: :premium}}
        ],
        default: %{route: :standard},
        return?: true
      })

    assert {:ok, %{route: :premium}} = Switch.select(switch, %{order: %{tier: :premium}})
    assert {:ok, %{route: :standard}} = Switch.select(switch, %{order: %{tier: :standard}})
  end

  test "reports missing switch inputs as execution errors" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{name: :premium, predicate: {FlowFunctions, :premium?}, then: :premium}
        ],
        return?: true
      })

    assert {:error, %ExecutionFailureError{message: message}} = Switch.select(switch, %{})
    assert message == "switch input :order not found"
  end

  test "switch input can select a path from the triggering result" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:result, :load_order, [:tier]},
        matches: [
          %{name: :premium, predicate: {__MODULE__, :premium_tier?}, then: :premium}
        ],
        default: :standard,
        return?: true
      })

    assert {:ok, :premium} = Switch.select(switch, %{tier: :premium})
  end

  test "reports missing switch result paths as execution errors" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:result, :load_order, [:missing]},
        matches: [
          %{name: :premium, predicate: {__MODULE__, :premium_tier?}, then: :premium}
        ],
        return?: true
      })

    assert {:error, %ExecutionFailureError{message: message}} =
             Switch.select(switch, %{tier: :premium})

    assert message == "switch path [:missing] not found"
  end

  test "block switch branches can return projected nested results" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{
            name: :premium,
            predicate: {FlowFunctions, :premium?},
            flow: [
              %{
                type: :step,
                name: :add,
                action: Add,
                params: %{amount: 2},
                context: %{},
                after: nil
              }
            ],
            return: {:result, :add, [:value]}
          }
        ],
        default: nil,
        return?: false
      })

    assert {:ok, 5} = Switch.select(switch, %{order: %{tier: :premium, value: 3}})
  end

  test "block switch default branches execute when no match is satisfied" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{name: :premium, predicate: {FlowFunctions, :premium?}, then: :premium}
        ],
        default: %{
          flow: [
            %{
              type: :step,
              name: :standard,
              action: NoParamsAction,
              params: %{},
              context: %{},
              after: nil
            }
          ],
          return: {:result, :standard}
        },
        return?: false
      })

    assert {:ok, %{result: "No params"}} =
             Switch.select(switch, %{order: %{tier: :standard}})
  end

  test "block switch branches without return emit branch result maps" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{
            name: :premium,
            predicate: {FlowFunctions, :premium?},
            flow: [
              %{
                type: :step,
                name: :standard,
                action: NoParamsAction,
                params: %{},
                context: %{},
                after: nil
              }
            ]
          }
        ],
        return?: false
      })

    assert {:ok, %{standard: [%{result: "No params"}]}} =
             Switch.select(switch, %{order: %{tier: :premium}})
  end

  test "block switch branch failures become switch execution errors" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{
            name: :premium,
            predicate: {FlowFunctions, :premium?},
            flow: [
              %{
                type: :step,
                name: :fail,
                action: Fail,
                params: %{},
                context: %{},
                after: nil
              }
            ],
            return: {:result, :fail}
          }
        ],
        return?: false
      })

    assert {:error, %ExecutionFailureError{message: message}} =
             silence_logger(fn -> Switch.select(switch, %{order: %{tier: :premium}}) end)

    assert message == "switch branch failed"
  end

  test "rejects ambiguous direct switch match IR" do
    assert_raise ArgumentError, ~r/switch matches must contain only one of then or flow/, fn ->
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{
            name: :premium,
            predicate: {FlowFunctions, :premium?},
            then: :premium,
            flow: []
          }
        ],
        return?: true
      })
    end
  end

  test "implements the minimal Runic protocol surface" do
    switch =
      Switch.new(%{
        type: :switch,
        name: :route,
        on: {:input, :order},
        matches: [
          %{name: :premium, predicate: {FlowFunctions, :premium?}, then: :premium}
        ],
        return?: true
      })

    assert Runic.Component.hash(switch) == switch.hash
    assert Runic.Component.inputs(switch) == [input: [type: :any, doc: "Switch input"]]
    assert Runic.Component.outputs(switch) == [output: [type: :any, doc: "Switch output"]]

    assert %Workflow{} = Runic.Transmutable.to_workflow(switch)
  end
end
