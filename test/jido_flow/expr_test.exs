defmodule JidoActionTest.Flow.ExprTest do
  use ExUnit.Case, async: true

  alias Jido.Expr
  alias Jido.Flow
  alias Jido.Flow.{Builder, Choice, Codec, Condition, Ref, Step}
  alias Jido.Flow.DSL.Expression
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "Flow parses transparent calculations and optional wrappers" do
    source =
      quote(do: %{total: input(:quantity) * input(:price), label: expr("Hi " <> input(:name))})

    assert {:ok, value} = Expression.parse(source)
    assert value.total == Expr.new!(:multiply, [Ref.input(:quantity), Ref.input(:price)])
    assert value.label == Expr.new!(:concat, ["Hi ", Ref.input(:name)])

    assert {:ok, %{total: 6, label: "Hi Ada"}} =
             Jido.Exec.run(output_flow(value), %{quantity: 2, price: 3, name: "Ada"})
  end

  test "direct, Builder, and stored calculations have the same model and result" do
    total = Expr.new!(:multiply, [Ref.result("load", :quantity), Ref.input(:price)])
    label = Expr.new!(:concat, [Ref.context(:prefix), Ref.input(:name)])

    step =
      Step.new!(
        name: "load",
        action: EchoParamsAction,
        params: %{quantity: Expr.new!(:add, [Ref.input(:quantity), 1])}
      )

    direct =
      Flow.new!(name: "calculated", components: [step], output: %{total: total, label: label})

    assert {:ok, built} =
             Builder.new(name: "calculated")
             |> Builder.step("load", EchoParamsAction, step.params)
             |> Builder.output(direct.output)
             |> Builder.build()

    assert built == direct
    assert {:ok, document, registry} = Codec.encode(built)
    assert document["version"] == 2

    assert {:ok, restored} =
             document |> JSON.encode!() |> JSON.decode!() |> Codec.decode(registry)

    assert restored == direct
    assert Flow.semantic_identity(restored) == Flow.semantic_identity(direct)

    for flow <- [direct, built, restored] do
      assert Jido.Exec.run(flow, %{quantity: 2, price: 3, name: "Ada"}, %{prefix: "Hi "}) ==
               {:ok, %{total: 9, label: "Hi Ada"}}

      assert {:ok, execution} =
               Jido.Exec.start(flow, %{quantity: 2, price: 3, name: "Ada"}, %{prefix: "Hi "})

      assert {:ok, execution} = Jido.Exec.continue(execution)
      assert Jido.Exec.result(execution) == {:ok, %{total: 9, label: "Hi Ada"}}
    end
  end

  test "Boolean references and literals are strict conditions and short circuit" do
    for {ast, input, expected} <- [
          {quote(do: input(:enabled)), %{enabled: true}, true},
          {quote(do: not input(:enabled)), %{enabled: false}, true},
          {quote(do: false and input(:missing)), %{}, false},
          {quote(do: true or 1 / 0 > 0), %{}, true}
        ] do
      assert {:ok, condition} = Expression.parse_condition(ast)
      assert Jido.Exec.run(choice_flow(condition), input) == {:ok, %{selected: expected}}
    end

    for value <- [nil, 0, "true", :ready] do
      assert {:error, error} = Jido.Exec.run(choice_flow(Ref.input(:enabled)), %{enabled: value})
      assert error.details.reason == :invalid_boolean_operand
    end

    assert Jido.Exec.run(choice_flow(true)) == {:ok, %{selected: true}}
    assert Jido.Exec.run(choice_flow(false)) == {:ok, %{selected: false}}

    assert Jido.Exec.run(choice_flow(Condition.not(Ref.input(:enabled))), %{enabled: false}) ==
             {:ok, %{selected: true}}
  end

  test "nested result references remain dependencies even when skipped" do
    expression = Expr.new!(:any, [true, Expr.new!(:eq, [Ref.result(:later, :value), 1])])
    first = Step.new!(name: "first", action: EchoParamsAction, params: %{selected: expression})
    later = Step.new!(name: "later", action: EchoParamsAction, params: %{value: 1})

    flow =
      Flow.new!(
        name: "nested_dependencies",
        components: [first, later],
        output: Ref.result("first")
      )

    assert Jido.Flow.Component.reference_dependencies(first) == ["later"]
    assert Jido.Exec.run(flow) == {:ok, %{selected: true}}

    assert {:error, error} =
             Flow.new(
               name: "unknown_ref",
               components: [Step.new!(name: "seed", action: EchoParamsAction)],
               output: %{value: expression}
             )

    assert error.details.component == "later"

    assert {:error, _} =
             Step.new(
               name: "bad_scope",
               action: EchoParamsAction,
               params: %{value: Expr.new!(:add, [Ref.item(), 1])}
             )
  end

  test "operation failures and missing references keep a useful location" do
    assert {:error, error} = Jido.Exec.run(output_flow(%{nested: [Expr.new!(:divide, [1, 0])]}))
    assert error.details.operator == :divide
    assert error.details.expression_path == [:nested, 0]
    assert error.details.retry == false

    expression = Expr.new!(:concat, ["Hi ", Ref.input(:missing)])

    assert {:error, error} =
             Jido.Exec.run(output_flow(%{label: expression}), %{secret: "do not expose"})

    assert error.details.path == [:missing]
    assert error.details.expression_path == [:label, :operands, 1]
    refute inspect(error.details) =~ "do not expose"

    assert Jido.Exec.run(output_flow(%{is_nil: Expr.new!(:eq, [Ref.input(:value), nil])}), %{
             value: nil
           }) == {:ok, %{is_nil: true}}

    assert {:error, _} = Jido.Exec.run(output_flow(Expr.new!(:add, [1, 2])))
  end

  test "resolved private map keys are absent from complete Flow errors" do
    private_key = "private-token-as-key"
    private_value = String.duplicate("private-value", 100_000)
    expression = Expr.new!(:eq, [Ref.context(:secrets), nil])

    assert {:error, error} =
             Jido.Exec.run(output_flow(%{answer: expression}), %{}, %{
               secrets: %{private_key => %{private_key => private_value}}
             })

    assert error.details.reason == :max_binary_bytes
    assert error.details.expression_path == [:answer, :operands, 0]
    assert error.details.retry == false
    refute inspect(error, limit: :infinity) =~ private_key
    refute inspect(error, limit: :infinity) =~ "private-value"
    refute inspect(Jido.Flow.Error.to_map(error), limit: :infinity) =~ private_key
  end

  test "operations preserve all local reference scopes" do
    scopes = [
      :flow,
      :map_collection,
      :map_params,
      :reduce_collection,
      :reduce_initial,
      :reduce_params,
      :iterate_initial,
      :iterate_params,
      :iterate_update,
      :iterate_completion
    ]

    for reference <- [
          Ref.item(),
          Ref.item_index(),
          Ref.item_id(),
          Ref.accumulator(),
          Ref.state(),
          Ref.iteration_index(),
          Ref.body_result()
        ],
        scope <- scopes do
      expression = Expr.new!(:eq, [reference, nil])

      case Ref.validate(reference, scope) do
        :ok ->
          assert :ok = Jido.Flow.Expression.validate(expression, scope)

        {:error, _} ->
          assert {:error, error} = Jido.Flow.Expression.validate(expression, scope)
          assert error.details.ref_type == reference.source
          assert error.details.scope == scope
      end
    end
  end

  test "malformed references inside calculated conditions return validation errors" do
    reference = %Ref{source: :unknown, path: []}
    expression = Expr.new!(:add, [reference, 1])
    assert {:error, error} = Condition.new(:eq, [expression, 2])
    assert error.details.type == :unknown
  end

  test "iterator completion failures retain the expression and reference locations" do
    iterator =
      Jido.Flow.Iterate.new!(
        name: "loop",
        action: EchoParamsAction,
        state: [schema: [], initial: %{}, update: %{}],
        completion: Expr.new!(:gt, [Expr.new!(:add, [Ref.input(:missing), 1]), 0]),
        max_iterations: 2
      )

    flow = Flow.new!(name: "iterator_error", components: [iterator], output: Ref.result("loop"))
    assert {:error, error} = Jido.Exec.run(flow)
    assert error.details.phase == :iterate_completion
    assert error.details.path == [:missing]
    assert error.details.expression_path == [:operands, 0, :operands, 0]
    assert error.details.retry == false
  end

  test "version one remains stable and literal maps are never expression nodes" do
    literal = %{"$expr" => %{"operator" => "add", "operands" => [1, 2]}}
    legacy = output_flow(literal)
    assert {:ok, document, registry} = Codec.encode(legacy)
    assert document["version"] == 1
    assert {:ok, restored} = Codec.decode(document, registry)
    assert Jido.Exec.run(restored) == {:ok, literal}
    expression = output_flow(%{value: Expr.new!(:add, [1, 2])})
    assert {:ok, expression_document, expression_registry} = Codec.encode(expression)

    assert {:error, _} =
             Codec.decode(Map.put(expression_document, "version", 1), expression_registry)

    refute Flow.semantic_identity(expression) ==
             Flow.semantic_identity(output_flow(%{value: %{operator: :add, operands: [1, 2]}}))
  end

  test "helper and legacy condition spellings produce the same Flow model" do
    assert {:ok, from_dsl} =
             Expression.parse_condition(quote(do: input(:score) * 2 >= 80 and input(:enabled)))

    from_helper =
      Expr.new!(:all, [
        Expr.new!(:gte, [Expr.new!(:multiply, [Ref.input(:score), 2]), 80]),
        Ref.input(:enabled)
      ])

    assert choice_flow(from_dsl) == choice_flow(from_helper)
  end

  test "malformed stored expressions fail with JSON paths and no atom creation" do
    assert {:ok, document, registry} = Codec.encode(output_flow(Expr.new!(:add, [1, 2])))
    unknown = "unknown_operator_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    for {record, expected_path} <- [
          {%{"operator" => unknown, "operands" => [1, 2]}, ["output", "$expr", "operator"]},
          {%{"operator" => "add", "operands" => [1]}, ["output", "$expr"]},
          {%{"operator" => "add", "operands" => "invalid"}, ["output", "$expr", "operands"]},
          {%{"operator" => "add", "operands" => [1, 2], "call" => "System.halt"},
           ["output", "$expr", "call"]}
        ] do
      assert {:error, error} =
               Codec.decode(%{document | "output" => %{"$expr" => record}}, registry)

      assert error.details.path == expected_path
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "nested invalid expression definitions and evaluation limits stay structured" do
    for invalid <- [
          %Expr{operator: :unknown, operands: []},
          %Expr{operator: :add, operands: [1 | :tail]},
          Expr.new!(:add, [fn -> 1 end, 2])
        ] do
      assert {:error, _} =
               Step.new(name: "invalid", action: EchoParamsAction, params: %{value: invalid})
    end

    deep = Enum.reduce(1..70, 1, fn _, value -> Expr.new!(:negate, [value]) end)
    assert {:error, _} = Step.new(name: "deep", action: EchoParamsAction, params: %{value: deep})

    assert {:error, error} =
             Jido.Exec.run(
               output_flow(%{value: Expr.new!(:concat, [Ref.input(:text), Ref.input(:text)])}),
               %{text: String.duplicate("a", 400_000)}
             )

    assert error.details.reason == :max_binary_bytes
    refute Map.has_key?(error.details, :text)
  end

  defp output_flow(output),
    do:
      Flow.new!(
        name: "expression_output",
        components: [Step.new!(name: "seed", action: EchoParamsAction)],
        output: output
      )

  defp choice_flow(condition) do
    Flow.new!(
      name: "expression_choice",
      components: [
        Choice.new!(
          name: "route",
          options: [
            [
              name: "yes",
              condition: condition,
              action: EchoParamsAction,
              params: %{selected: true}
            ]
          ],
          fallback: [action: EchoParamsAction, params: %{selected: false}]
        )
      ],
      output: Ref.result("route")
    )
  end
end
