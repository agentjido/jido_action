defmodule Jido.Flow.CompilerRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Choice, Compiler, Condition, Node, Reduce, Ref}
  alias Jido.Flow.Map, as: FlowMap

  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

  test "executes every comparison operator with runtime operands" do
    cases = [
      {Condition.eq(Ref.input(:left), Ref.input(:right)), 1, 1},
      {Condition.neq(Ref.input(:left), Ref.input(:right)), 1, 2},
      {Condition.lt(Ref.input(:left), Ref.input(:right)), 1, 2},
      {Condition.lte(Ref.input(:left), Ref.input(:right)), 2, 2},
      {Condition.gt(Ref.input(:left), Ref.input(:right)), 2, 1},
      {Condition.gte(Ref.input(:left), Ref.input(:right)), "b", "a"},
      {Condition.in(Ref.input(:left), Ref.input(:right)), :two, [:one, :two, :three]}
    ]

    for {condition, left, right} <- cases do
      assert {:ok, %{value: 2}} =
               Exec.run(choice_flow(condition), %{left: left, right: right}, %{})
    end
  end

  test "selects the first matching Choice option" do
    always = Condition.eq(Ref.value(1), Ref.value(1))

    flow =
      Flow.new!(
        name: "first_matching_choice",
        nodes: [
          Choice.new!(
            name: "route",
            options: [
              [
                name: "first",
                condition: always,
                action: Add,
                input: %{value: 1, amount: 1}
              ],
              [
                name: "second",
                condition: always,
                action: Multiply,
                input: %{value: 10, amount: 10}
              ]
            ],
            fallback: [action: Multiply, input: %{value: 20, amount: 20}]
          )
        ],
        return: Ref.result("route")
      )

    assert {:ok, %{value: 2}} = Exec.run(flow, %{}, %{})
  end

  test "uses the same Map item identity in records and target inputs" do
    flow =
      Flow.new!(
        name: "map_item_identity",
        nodes: [
          FlowMap.new!(
            name: "mapped",
            collection: Ref.value([:first, :second]),
            action: EchoParamsAction,
            input: %{
              id: Ref.item_id(),
              index: Ref.item_index(),
              value: Ref.item()
            },
            on_error: :collect_errors
          )
        ],
        return: Ref.result("mapped")
      )

    assert {:ok, %{errors: [], results: results}} = Exec.run(flow, %{}, %{})

    assert [
             %{index: 0, item_id: first_id, output: %{id: first_id, index: 0, value: :first}},
             %{index: 1, item_id: second_id, output: %{id: second_id, index: 1, value: :second}}
           ] = results

    assert first_id != second_id
  end

  test "short-circuits all, any, and not conditions" do
    true_condition = Condition.eq(Ref.value(1), Ref.value(1))
    false_condition = Condition.eq(Ref.value(1), Ref.value(2))

    cases = [
      {Condition.all([true_condition, true_condition]), 2},
      {Condition.all([false_condition, invalid_ordering()]), 20},
      {Condition.any([true_condition, invalid_ordering()]), 2},
      {Condition.any([false_condition, false_condition]), 20},
      {Condition.not(false_condition), 2},
      {Condition.not(true_condition), 20}
    ]

    for {condition, value} <- cases do
      assert {:ok, %{value: ^value}} = Exec.run(choice_flow(condition), %{}, %{})
    end
  end

  test "returns condition errors from each boolean group" do
    for condition <- [
          Condition.all([invalid_ordering()]),
          Condition.any([invalid_ordering()]),
          Condition.not(invalid_ordering())
        ] do
      assert {:error,
              %ExecutionFailureError{
                message: "invalid choice condition operands",
                details: %{reason: :invalid_ordering_operands}
              }} = Exec.run(choice_flow(condition), %{}, %{})
    end
  end

  test "classifies invalid ordering and membership operands" do
    invalid_ordering_values = [
      {1, "one", :number, :binary},
      {[], %{}, :list, :map},
      {:one, {}, :atom, :tuple},
      {self(), 1, :other, :number}
    ]

    for {left, right, left_type, right_type} <- invalid_ordering_values do
      condition = Condition.lt(Ref.input(:left), Ref.input(:right))

      assert {:error,
              %ExecutionFailureError{
                details: %{
                  reason: :invalid_ordering_operands,
                  left_type: ^left_type,
                  right_type: ^right_type
                }
              }} = Exec.run(choice_flow(condition), %{left: left, right: right}, %{})
    end

    condition = Condition.in(Ref.input(:left), Ref.input(:right))

    for right <- [%{}, [1 | :tail]] do
      assert {:error,
              %ExecutionFailureError{
                details: %{reason: :invalid_membership_right_operand}
              }} = Exec.run(choice_flow(condition), %{left: 1, right: right}, %{})
    end
  end

  test "resolves nested maps, lists, alternate map keys, and list indexes" do
    flow =
      Flow.new!(
        name: "expression_resolution",
        nodes: [
          Node.new!(
            name: "echo",
            action: EchoParamsAction,
            input: %{
              values: [Ref.input(:value), Ref.context(:trace)],
              alternate_key: Ref.input([:data, :value]),
              indexed: Ref.input([:items, 1]),
              missing_index: Ref.input([:items, 9]),
              scalar_path: Ref.input([:value, :missing])
            }
          )
        ],
        return: Ref.result("echo")
      )

    assert {:ok,
            %{
              values: [1, "trace"],
              alternate_key: 2,
              indexed: :one,
              missing_index: nil,
              scalar_path: nil
            }} =
             Exec.run(
               flow,
               %{value: 1, data: %{"value" => 2}, items: [:zero, :one]},
               %{trace: "trace"}
             )
  end

  test "classifies invalid Map collections without starting item work" do
    flow =
      Flow.new!(
        name: "invalid_map_collection",
        nodes: [
          FlowMap.new!(
            name: "mapped",
            collection: Ref.input(:items),
            action: EchoParamsAction,
            input: %{item: Ref.item()}
          )
        ],
        return: Ref.result("mapped")
      )

    cases = [
      {nil, nil},
      {%{}, :map},
      {"items", :binary},
      {1, :number},
      {:items, :atom},
      {{:items}, :tuple},
      {self(), :other},
      {Output.raw([]), :action_output},
      {[1 | :tail], :list}
    ]

    for {items, value_type} <- cases do
      assert {:error,
              %ExecutionFailureError{
                message: "map collection must resolve to a proper list",
                details: %{value_type: ^value_type}
              }} = Exec.run(flow, %{items: items}, %{})
    end
  end

  test "handles empty collected Maps and rejects invalid Reduce data" do
    empty_map =
      Flow.new!(
        name: "empty_map",
        nodes: [
          FlowMap.new!(
            name: "mapped",
            collection: Ref.value([]),
            action: EchoParamsAction,
            input: %{item: Ref.item()},
            on_error: :collect_errors
          )
        ],
        return: Ref.result("mapped")
      )

    assert {:ok, %{results: [], errors: []}} = Exec.run(empty_map, %{}, %{})

    reduce =
      Flow.new!(
        name: "invalid_reduce",
        nodes: [
          Reduce.new!(
            name: "reduced",
            collection: Ref.input(:items),
            initial: Ref.input(:initial),
            action: EchoParamsAction,
            input: %{accumulator: Ref.accumulator(), item: Ref.item()}
          )
        ],
        return: Ref.result("reduced")
      )

    assert {:error,
            %ExecutionFailureError{message: "reduce collection must resolve to a proper list"}} =
             Exec.run(reduce, %{items: :bad, initial: %{}}, %{})

    assert {:error,
            %ExecutionFailureError{
              message: "reduce initial value must be a map or Jido.Action.Output"
            }} = Exec.run(reduce, %{items: [], initial: :bad}, %{})
  end

  test "rejects invalid inputs at the validated compiler boundary" do
    flow =
      Flow.new!(
        name: "compiler_boundary",
        nodes: [Node.new!(name: "echo", action: EchoParamsAction)],
        return: Ref.result("echo")
      )

    assert {:error, error} =
             Compiler.runtime_workflow_validated(
               flow,
               [],
               %{},
               [],
               fn _action, _params, _context, _execution_id, _owner -> {:ok, %{}} end,
               "execution-id"
             )

    assert Exception.message(error) == "flow input and context must be maps"
  end

  defp choice_flow(condition) do
    Flow.new!(
      name: "condition_runtime",
      nodes: [
        Choice.new!(
          name: "route",
          options: [
            [
              name: "matched",
              condition: condition,
              action: Add,
              input: %{value: 1, amount: 1}
            ]
          ],
          fallback: [action: Multiply, input: %{value: 10, amount: 2}]
        )
      ],
      return: Ref.result("route")
    )
  end

  defp invalid_ordering do
    Condition.lt(Ref.value(%{}), Ref.value(1))
  end
end
