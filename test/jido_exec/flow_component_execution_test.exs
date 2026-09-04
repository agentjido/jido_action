defmodule JidoActionTest.Exec.FlowComponentExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Output
  alias Jido.Action.Error.ExecutionFailureError, as: ActionExecutionFailureError
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Error.ExecutionFailureError
  alias Jido.Flow.{Choice, Condition, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap

  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction, ErrorAction, Multiply}

  defmodule CollectedErrorAction do
    use Jido.Action, name: "collected_error_action"

    @impl true
    def run(%{item: item}, %{owner: owner, ref: ref}) do
      send(owner, {ref, :ready, item, self()})

      receive do
        {^ref, :release} ->
          case item do
            :invalid -> {:error, Jido.Action.Error.validation_error("invalid item", field: :item)}
            :retry -> {:error, Jido.Action.Error.execution_error("try again", retry: true)}
            :ok -> {:ok, %{accepted: true}}
          end
      end
    end
  end

  test "collects structured errors in source order after reversed item completion" do
    ref = make_ref()
    owner = self()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:jido, :flow, :map, :item, :stop], [:jido, :flow, :map, :item, :error]],
        fn _event, _measurements, metadata, _config ->
          if metadata.target == CollectedErrorAction do
            send(owner, {ref, :completed, metadata.item_index})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    flow =
      Flow.new!(
        name: "collected_structured_errors",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [:invalid, :retry, :ok],
            action: CollectedErrorAction,
            params: %{item: Ref.item()},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    task =
      Task.async(fn -> Exec.run(flow, %{}, %{owner: owner, ref: ref}, max_concurrency: 3) end)

    try do
      workers =
        for item <- [:invalid, :retry, :ok], into: %{} do
          assert_receive {^ref, :ready, ^item, pid}, 1_000
          {item, pid}
        end

      for {item, index} <- [{:ok, 2}, {:retry, 1}, {:invalid, 0}] do
        monitor = Process.monitor(workers[item])
        send(workers[item], {ref, :release})
        assert_receive {^ref, :completed, ^index}, 1_000
        assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
      end

      assert {:ok,
              %{
                items: [
                  %{status: :error, error: invalid},
                  %{status: :error, error: retry},
                  %{status: :ok, value: %{accepted: true}}
                ]
              }} = Task.await(task)

      assert %{
               type: :validation_error,
               message: "invalid item",
               retryable?: false,
               details: %{field: :item, item_index: 0, item_id: invalid_id}
             } = invalid

      assert %{
               type: :execution_error,
               message: "try again",
               retryable?: true,
               details: %{retry: true, item_index: 1, item_id: retry_id}
             } = retry

      assert is_binary(invalid_id)
      assert is_binary(retry_id)
      assert invalid_id != retry_id

      for error <- [invalid, retry] do
        assert Map.keys(error) |> Enum.sort() == [:details, :message, :retryable?, :type]
        assert error.details.node == "mapped"
        assert error.details.target == CollectedErrorAction
        assert error.details.phase == :map_target_execution
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "collected reference errors preserve details without invented target identity" do
    flow =
      Flow.new!(
        name: "collected_reference_error",
        components: [
          FlowMap.new!(
            name: "mapped",
            collection: [%{}],
            action: EchoParamsAction,
            params: %{item: Ref.item(:missing)},
            on_error: :collect_errors
          )
        ],
        output: %{items: Ref.result("mapped")}
      )

    assert {:ok, %{items: [%{status: :error, error: error}]}} = Exec.run(flow)

    assert %{
             type: :flow_execution_error,
             retryable?: false,
             details: %{reason: :missing_key, path: [:missing], ref_type: :item}
           } = error

    refute Map.has_key?(error.details, :item_id)
    refute Map.has_key?(error.details, :item_index)
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
