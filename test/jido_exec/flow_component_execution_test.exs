defmodule JidoActionTest.Exec.FlowComponentExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Output
  alias Jido.Action.Error.ExecutionFailureError, as: ActionExecutionFailureError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Dynamic
  alias Jido.Flow.Error.ExecutionFailureError
  alias Jido.Flow.{Choice, Condition, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap

  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction, ErrorAction, Multiply}

  defmodule ContinueToAdd do
    use Jido.Action,
      name: "component_continue_to_add",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(%{value: value}, _context) do
      {:continue, %{value: value, amount: 2}, JidoActionTest.Fixtures.Actions.Add}
    end
  end

  defmodule ContinueReduce do
    use Jido.Action, name: "component_continue_reduce"

    @impl true
    def run(params, _context) do
      {:continue, params, JidoActionTest.Fixtures.Actions.ReduceProbeAction}
    end
  end

  defmodule DynamicDecision do
    use Jido.Action, name: "component_dynamic_decision"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule DynamicExpander do
    use Jido.Action, name: "component_dynamic_expander"

    @impl true
    def run(%{value: value}, _context) when value < 2 do
      {:continue, %{value: value, amount: 1}, JidoActionTest.Fixtures.Actions.Add}
    end

    def run(%{value: value}, _context), do: {:ok, %{value: value}}
  end

  defmodule ContinueToError do
    use Jido.Action, name: "component_continue_to_error"

    @impl true
    def run(_params, _context) do
      {:continue, %{error_type: :validation}, JidoActionTest.Fixtures.Actions.ErrorAction}
    end
  end

  defmodule ContinueToInvalidTarget do
    use Jido.Action, name: "component_continue_to_invalid_target"

    @impl true
    def run(_params, _context), do: {:continue, %{}, :not_an_executable}
  end

  defmodule DynamicDecisionContinuation do
    use Jido.Action, name: "component_dynamic_decision_continuation"

    @impl true
    def run(%{value: value}, _context) do
      {:continue, %{value: value, amount: 1}, JidoActionTest.Fixtures.Actions.Add}
    end
  end

  defmodule DynamicAlwaysContinue do
    use Jido.Action, name: "component_dynamic_always_continue"

    @impl true
    def run(%{value: value}, _context) do
      {:continue, %{value: value, amount: 1}, JidoActionTest.Fixtures.Actions.Add}
    end
  end

  defmodule DynamicOpaqueDecision do
    use Jido.Action, name: "component_dynamic_opaque_decision"

    @impl true
    def run(_params, _context), do: {:ok, Output.raw(:not_a_map)}
  end

  test "keeps target ownership on public execution errors" do
    cases = [
      {target_error_flow(:step), :step_execution, %{node: "target", action: ErrorAction}},
      {target_error_flow(:choice), :choice_target_execution,
       %{node: "target", option: "selected", target: ErrorAction}},
      {target_error_flow(:map), :map_target_execution,
       %{node: "target", target: ErrorAction, item_index: 0}},
      {target_error_flow(:reduce), :reduce_target_execution,
       %{node: "target", target: ErrorAction, item_index: 0}}
    ]

    for {flow, phase, ownership} <- cases do
      assert {:error, %ActionExecutionFailureError{details: details}} = Exec.run(flow)
      assert details.phase == phase
      assert Map.take(details, Map.keys(ownership)) == ownership

      if phase in [:map_target_execution, :reduce_target_execution] do
        assert is_binary(details.item_id)
      end
    end
  end

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
      assert Exec.run(choice_flow(condition), %{left: left, right: right}, %{}) ==
               {:ok, %{value: 2}}
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

    assert Exec.run(flow) == {:ok, %{value: 2}}
  end

  test "Choice and Map use the universal continuation boundary" do
    choice =
      Choice.new!(
        name: "chosen",
        options: [
          [
            name: "continue",
            condition: Condition.eq(1, 1),
            action: ContinueToAdd,
            params: %{value: 3}
          ]
        ],
        fallback: [action: EchoParamsAction, params: %{value: 0}]
      )

    mapped =
      FlowMap.new!(
        name: "mapped",
        collection: [1, 2],
        action: ContinueToAdd,
        params: %{value: Ref.item()},
        on_error: :collect_errors,
        after: ["chosen"]
      )

    flow =
      Flow.new!(
        name: "choice_map_continuations",
        components: [choice, mapped],
        output: %{choice: Ref.result("chosen"), mapped: Ref.result("mapped")}
      )

    assert Exec.run(flow, %{}, %{}, max_concurrency: 2) ==
             {:ok,
              %{
                choice: %{value: 5},
                mapped: [
                  %{status: :ok, value: %{value: 3}},
                  %{status: :ok, value: %{value: 4}}
                ]
              }}
  end

  test "Map collect_errors owns continuation target failures" do
    flow =
      Flow.new!(
        name: "map_continuation_failure",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [1],
            action: ContinueToError,
            params: %{value: Ref.item()},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    assert {:ok, %{items: [%{status: :error, error: %{message: "Validation error"}}]}} =
             Exec.run(flow)
  end

  test "Map collect_errors owns an invalid continuation target" do
    flow =
      Flow.new!(
        name: "map_invalid_continuation_target",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [1],
            action: ContinueToInvalidTarget,
            params: %{value: Ref.item()},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    assert {:ok, %{items: [%{status: :error, error: %{message: message}}]}} = Exec.run(flow)
    assert message == "action returned an invalid continuation target"
  end

  test "Reduce resumes its serial fold after each continuation target" do
    flow =
      Flow.new!(
        name: "reduce_continuations",
        components: [
          Reduce.new!(
            name: "reduced",
            collection: [3, 2, 1],
            initial: %{value: 10},
            action: ContinueReduce,
            params: %{
              accumulator: Ref.accumulator(),
              item: Ref.item(),
              index: Ref.item_index(),
              item_id: Ref.item_id(),
              outcome: :subtract
            }
          )
        ],
        output: Ref.result("reduced")
      )

    assert Exec.run(flow, %{}, %{test_pid: self()}) == {:ok, %{value: 4}}

    assert_receive {JidoActionTest.Fixtures.Actions.ReduceProbeAction, :called, 0, _, 3,
                    %{value: 10}}

    assert_receive {JidoActionTest.Fixtures.Actions.ReduceProbeAction, :called, 1, _, 2,
                    %{value: 7}}

    assert_receive {JidoActionTest.Fixtures.Actions.ReduceProbeAction, :called, 2, _, 1,
                    %{value: 5}}
  end

  test "Dynamic repeats decision and expander calls inside one execution graph" do
    dynamic =
      Dynamic.new!(
        name: "reason",
        decision: DynamicDecision,
        expander: DynamicExpander,
        params: %{value: Ref.input(:value)},
        max_continuations: 2
      )

    flow = Flow.new!(name: "dynamic_loop", components: [dynamic], output: Ref.result("reason"))

    assert Exec.run(flow, %{value: 0}) == {:ok, %{value: 2}}

    assert {:ok, execution} = Exec.start(flow, %{value: 0})
    assert {:ok, execution} = Exec.continue(execution)

    assert [first, second] = Exec.continuations(execution)
    assert first.sequence == 1
    assert second.sequence == 2
    assert first.depth == 1
    assert second.depth == 2
    assert second.parent == first.occurrence
    refute Map.has_key?(first, :input)
    refute Map.has_key?(first, :output)

    continuation_names =
      execution
      |> Exec.workflow()
      |> Runic.Workflow.steps()
      |> Enum.map(& &1.name)
      |> Enum.filter(&is_binary/1)

    assert Enum.any?(continuation_names, &String.starts_with?(&1, "$continue/"))
  end

  test "Dynamic accepts a continuation from its decision Action" do
    dynamic =
      Dynamic.new!(
        name: "reason",
        decision: DynamicDecisionContinuation,
        expander: DynamicDecision,
        params: %{value: Ref.input(:value)},
        max_continuations: 1
      )

    flow =
      Flow.new!(
        name: "dynamic_decision_continue",
        components: [dynamic],
        output: Ref.result("reason")
      )

    assert Exec.run(flow, %{value: 2}) == {:ok, %{value: 3}}
  end

  test "Dynamic enforces its local continuation bound" do
    dynamic =
      Dynamic.new!(
        name: "reason",
        decision: DynamicDecision,
        expander: DynamicAlwaysContinue,
        params: %{value: Ref.input(:value)},
        max_continuations: 1
      )

    flow =
      Flow.new!(name: "dynamic_local_limit", components: [dynamic], output: Ref.result("reason"))

    assert {:error, %ExecutionFailureError{message: "dynamic continuation limit exceeded"}} =
             Exec.run(flow, %{value: 0})
  end

  test "Dynamic requires plain maps at both Action inputs" do
    invalid_decision =
      Dynamic.new!(
        name: "reason",
        decision: DynamicDecision,
        expander: DynamicExpander,
        params: Ref.input(:value),
        max_continuations: 1
      )

    invalid_expander =
      Dynamic.new!(
        name: "reason",
        decision: DynamicOpaqueDecision,
        expander: DynamicExpander,
        params: %{},
        max_continuations: 1
      )

    for {name, dynamic, input, phase} <- [
          {"dynamic_invalid_decision", invalid_decision, %{value: 1}, :dynamic_decision_input},
          {"dynamic_invalid_expander", invalid_expander, %{}, :dynamic_expander_input}
        ] do
      flow = Flow.new!(name: name, components: [dynamic], output: Ref.result("reason"))

      assert {:error, %ExecutionFailureError{details: %{phase: ^phase}}} =
               Exec.run(flow, input)
    end
  end

  test "uses stable Map item identity in target inputs" do
    flow =
      Flow.new!(
        name: "map_item_identity",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [:first, :second],
            action: EchoParamsAction,
            params: %{id: Ref.item_id(), index: Ref.item_index(), value: Ref.item()},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    assert {:ok,
            %{
              items: [
                %{status: :ok, value: %{id: first_id, index: 0, value: :first}},
                %{status: :ok, value: %{id: second_id, index: 1, value: :second}}
              ]
            }} = Exec.run(flow)

    assert is_binary(first_id)
    assert is_binary(second_id)
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
      assert Exec.run(choice_flow(condition)) == {:ok, %{value: value}}
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
              }} = Exec.run(choice_flow(condition))
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
              }} = Exec.run(choice_flow(condition), %{left: left, right: right})
    end

    condition = Condition.in(Ref.input(:left), Ref.input(:right))

    for right <- [%{}, [1 | :tail]] do
      assert {:error,
              %ExecutionFailureError{details: %{reason: :invalid_membership_right_operand}}} =
               Exec.run(choice_flow(condition), %{left: 1, right: right})
    end
  end

  test "resolves nested values and alternate map keys" do
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

    assert Exec.run(
             flow,
             %{value: 1, data: %{"value" => 2}, items: [:zero, :one], stored_nil: nil},
             %{trace: "trace"}
           ) ==
             {:ok, %{values: [1, "trace"], alternate_key: 2, indexed: :one, stored_nil: nil}}
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
              }} = Exec.run(flow, %{value: 1, data: %{"value" => 2}, items: [:zero, :one]})

      assert path == ref.path
    end
  end

  test "classifies invalid Map collections" do
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
              }} = Exec.run(flow, %{items: items})
    end
  end

  test "handles empty Maps and rejects invalid Reduce data" do
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
        output: %{items: Ref.result("mapped")}
      )

    assert Exec.run(empty_map) == {:ok, %{items: []}}

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
             Exec.run(reduce, %{items: :bad, initial: %{}})

    assert {:error,
            %ExecutionFailureError{
              message: "reduce initial value must be a map or Jido.Action.Output"
            }} = Exec.run(reduce, %{items: [], initial: :bad})
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

  defp invalid_ordering, do: Condition.lt(%{}, 1)

  defp target_error_flow(:step) do
    Flow.new!(
      name: "step_target_error",
      components: [
        Step.new!(name: "target", action: ErrorAction, params: %{error_type: :validation})
      ],
      output: Ref.result("target")
    )
  end

  defp target_error_flow(:choice) do
    Flow.new!(
      name: "choice_target_error",
      components: [
        Choice.new!(
          name: "target",
          options: [
            [
              name: "selected",
              condition: Condition.eq(1, 1),
              action: ErrorAction,
              params: %{error_type: :validation}
            ]
          ],
          fallback: [action: ErrorAction, params: %{error_type: :validation}]
        )
      ],
      output: Ref.result("target")
    )
  end

  defp target_error_flow(:map) do
    Flow.new!(
      name: "map_target_error",
      components: [
        FlowMap.new!(
          name: "target",
          collection: [:item],
          action: ErrorAction,
          params: %{error_type: :validation}
        )
      ],
      output: Ref.result("target")
    )
  end

  defp target_error_flow(:reduce) do
    Flow.new!(
      name: "reduce_target_error",
      components: [
        Reduce.new!(
          name: "target",
          collection: [:item],
          initial: %{},
          action: ErrorAction,
          params: %{error_type: :validation}
        )
      ],
      output: Ref.result("target")
    )
  end
end
