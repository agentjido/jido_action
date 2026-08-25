defmodule JidoActionTest.Flow.Compiler.RuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Choice, Compiler, Condition, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap

  alias JidoActionTest.TestActions.{Add, EchoParamsAction, Multiply}

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
    always = Condition.eq(1, 1)

    flow =
      Flow.new!(
        name: "first_matching_choice",
        components: [
          Choice.new!(
            name: "route",
            options: [
              [
                name: "first",
                condition: always,
                action: Add,
                params: %{value: 1, amount: 1}
              ],
              [
                name: "second",
                condition: always,
                action: Multiply,
                params: %{value: 10, amount: 10}
              ]
            ],
            fallback: [action: Multiply, params: %{value: 20, amount: 20}]
          )
        ],
        output: Ref.result("route")
      )

    assert {:ok, %{value: 2}} = Exec.run(flow, %{}, %{})
  end

  test "uses the same Map item identity in records and target inputs" do
    flow =
      Flow.new!(
        name: "map_item_identity",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [:first, :second],
            action: EchoParamsAction,
            params: %{
              id: Ref.item_id(),
              index: Ref.item_index(),
              value: Ref.item()
            },
            on_error: :collect_errors
          )
        ],
        output: Ref.result("mapped")
      )

    assert {:ok, %{errors: [], results: results}} = Exec.run(flow, %{}, %{})

    assert [
             %{index: 0, item_id: first_id, output: %{id: first_id, index: 0, value: :first}},
             %{index: 1, item_id: second_id, output: %{id: second_id, index: 1, value: :second}}
           ] = results

    assert first_id != second_id
  end

  test "short-circuits all, any, and not conditions" do
    true_condition = Condition.eq(1, 1)
    false_condition = Condition.eq(1, 2)

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

  test "resolves nested maps, lists, alternate map keys, list indexes, and stored nil" do
    flow =
      Flow.new!(
        name: "expression_resolution",
        components: [
          Step.new!(
            name: "echo",
            action: EchoParamsAction,
            params: %{
              values: [Ref.input(:value), Ref.context(:trace)],
              alternate_key: Ref.input([:data, :value]),
              indexed: Ref.input([:items, 1]),
              stored_nil: Ref.input(:stored_nil)
            }
          )
        ],
        output: Ref.result("echo")
      )

    assert {:ok,
            %{
              values: [1, "trace"],
              alternate_key: 2,
              indexed: :one,
              stored_nil: nil
            }} =
             Exec.run(
               flow,
               %{value: 1, data: %{"value" => 2}, items: [:zero, :one], stored_nil: nil},
               %{trace: "trace"}
             )
  end

  test "rejects missing and non-traversable reference paths" do
    cases = [
      {Ref.input([:data, :missing]), :missing_key, :missing, [:data], :map},
      {Ref.input([:items, 9]), :missing_index, 9, [:items], :list},
      {Ref.input([:value, :missing]), :not_traversable, :missing, [:value], :number}
    ]

    for {ref, reason, segment, resolved_path, value_type} <- cases do
      flow =
        Flow.new!(
          name: "strict_expression_resolution",
          components: [
            Step.new!(name: "echo", action: EchoParamsAction, params: %{resolved: ref})
          ],
          output: Ref.result("echo")
        )

      assert {:error,
              %ExecutionFailureError{
                message: "flow reference path does not exist",
                details: %{
                  ref_type: :input,
                  path: path,
                  reason: ^reason,
                  segment: ^segment,
                  resolved_path: ^resolved_path,
                  value_type: ^value_type,
                  retry: false
                }
              }} =
               Exec.run(
                 flow,
                 %{value: 1, data: %{"value" => 2}, items: [:zero, :one]},
                 %{}
               )

      assert path == ref.path
    end
  end

  test "classifies invalid Map collections without starting item work" do
    flow =
      Flow.new!(
        name: "invalid_map_collection",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: Ref.input(:items),
            action: EchoParamsAction,
            params: %{item: Ref.item()}
          )
        ],
        output: Ref.result("mapped")
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
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [],
            action: EchoParamsAction,
            params: %{item: Ref.item()},
            on_error: :collect_errors
          )
        ],
        output: Ref.result("mapped")
      )

    assert {:ok, %{results: [], errors: []}} = Exec.run(empty_map, %{}, %{})

    reduce =
      Flow.new!(
        name: "invalid_reduce",
        components: [
          Reduce.new!(
            name: "reduced",
            collection: Ref.input(:items),
            initial: Ref.input(:initial),
            action: EchoParamsAction,
            params: %{accumulator: Ref.accumulator(), item: Ref.item()}
          )
        ],
        output: Ref.result("reduced")
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
        components: [Step.new!(name: "echo", action: EchoParamsAction)],
        output: Ref.result("echo")
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
      components: [
        Choice.new!(
          name: "route",
          options: [
            [
              name: "matched",
              condition: condition,
              action: Add,
              params: %{value: 1, amount: 1}
            ]
          ],
          fallback: [action: Multiply, params: %{value: 10, amount: 2}]
        )
      ],
      output: Ref.result("route")
    )
  end

  defp invalid_ordering do
    Condition.lt(%{}, 1)
  end
end
