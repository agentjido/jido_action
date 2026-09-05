defmodule JidoActionTest.Flow.ExprBoundaryTest do
  use ExUnit.Case, async: true

  alias Jido.Expr
  alias Jido.Flow
  alias Jido.Flow.{Builder, Choice, Codec, Condition, Iterate, Ref, Step}
  alias Jido.Flow.DSL.Expression
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "encoding rejects expression documents that exceed the reader's depth limit" do
    for count <- [1, 20] do
      flow = output_flow(%{value: nested_negate(count)})
      assert {:ok, document, registry} = Codec.encode(flow)
      assert {:ok, ^flow} = Codec.decode(document, registry)
    end

    flow = output_flow(%{value: nested_negate(40)})
    result = Codec.encode(flow)
    assert elem(result, 0) == :error
    {:error, error} = result
    assert error.message == "stored Flow exceeds its nesting limit"
    assert error.details.maximum_depth == 100
  end

  test "calculated conditions keep one budget across fields and authoring forms" do
    calculation = Expr.new!(:concat, [Ref.input(:data), ""])
    expression = Expr.new!(:eq, [calculation, Ref.input(:data)])

    assert {:ok, parsed} =
             Expression.parse_condition(quote(do: input(:data) <> "" == input(:data)))

    for condition <- [expression, parsed, Condition.eq(calculation, Ref.input(:data))] do
      assert {:ok, ^expression} = Condition.new(condition)
      choice = choice_flow(condition)
      assert {:ok, document, registry} = Codec.encode(choice)
      assert {:ok, ^choice} = Codec.decode(document, registry)
      assert Jido.Exec.run(choice, %{data: "short"}) == {:ok, %{selected: true}}

      for flow <- [output_flow(%{selected: condition}), choice, iterator_flow(condition)] do
        assert {:error, error} = Jido.Exec.run(flow, %{data: String.duplicate("x", 300_000)})
        assert error.details.reason == :max_binary_bytes
        assert error.details.retry == false
      end
    end
  end

  test "Boolean groups keep the full calculated condition in the shared evaluator" do
    calculation = Expr.new!(:concat, [Ref.input(:data), ""])
    comparison = Expr.new!(:eq, [calculation, Ref.input(:data)])
    legacy = Condition.eq(1, 1)

    for condition <- [
          Condition.all([legacy, Condition.eq(calculation, Ref.input(:data))]),
          Condition.any([Condition.eq(calculation, Ref.input(:data)), legacy]),
          Condition.not(Condition.eq(calculation, Ref.input(:data))),
          Expr.new!(:all, [Expr.new!(:eq, [1, 1]), comparison])
        ] do
      assert {:ok, %Expr{}} = Condition.new(condition)

      assert {:error, error} =
               Jido.Exec.run(choice_flow(condition), %{data: String.duplicate("x", 300_000)})

      assert error.details.reason == :max_binary_bytes
    end
  end

  test "plain data keeps its DSL, Builder, direct and version-one storage contracts" do
    cases = [
      %{items: List.duplicate(1, 10_000)},
      %{text: String.duplicate("x", 1_048_577)},
      %{number: Bitwise.bsl(1, 4096)},
      %{nested: Enum.reduce(1..70, 1, fn _, value -> [value] end)}
    ]

    for {value, index} <- Enum.with_index(cases) do
      source = Macro.escape(value)
      assert {:ok, ^value} = Expression.parse(source)
      direct = output_flow(value)

      assert {:ok, built} =
               Builder.new(name: "expression_boundary")
               |> Builder.step("seed", EchoParamsAction, %{})
               |> Builder.output(value)
               |> Builder.build()

      assert built == direct
      assert module_flow(Module.concat(__MODULE__, "Plain#{index}"), source) == direct
      assert {:ok, document, registry} = Codec.encode(direct)
      assert document["version"] == 1
      assert {:ok, ^direct} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
      assert Jido.Exec.run(direct) == {:ok, value}
    end
  end

  test "plain in-memory data is not subject to expression depth limits" do
    value = %{nested: Enum.reduce(1..129, 1, fn _, data -> [data] end)}
    assert {:ok, ^value} = Expression.parse(Macro.escape(value))
    assert {:ok, ^value} = Jido.Flow.Expression.normalize(value)
    assert output_flow(value).output == value
  end

  test "actual operations still reject oversized operands in every authoring form" do
    for value <- [
          String.duplicate("x", 1_048_577),
          Bitwise.bsl(1, 4096),
          List.duplicate(1, 10_000),
          Enum.reduce(1..70, 1, fn _, data -> [data] end)
        ] do
      expression = Expr.new!(:eq, [value, value])
      assert {:error, _} = Expression.parse(quote(do: unquote(value) == unquote(value)))

      assert {:error, _} =
               Step.new(name: "seed", action: EchoParamsAction, params: %{v: expression})
    end
  end

  test "normalization counts Condition nodes after conversion to expressions" do
    conditions = List.duplicate(Condition.eq(1, 1), 4_000)
    expression = Expr.new!(:all, conditions)
    assert {:error, error} = Condition.new(:all, conditions)
    assert error.details.reason == :max_nodes
    assert {:error, error} = Jido.Flow.Expression.normalize(expression)
    assert error.details.reason == :max_nodes
  end

  test "plain-data parsing keeps malformed data and executable calls out of Flow values" do
    for value <- [
          [1 | 2],
          {:%{}, [], [{:value, 1} | 2]},
          {:%{}, [], [:invalid_pair]},
          quote(do: %{1.5 => 1}),
          quote(do: %{nested: [Date.utc_today()]}),
          quote(do: %{duplicate: 1, duplicate: 2})
        ] do
      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} = Expression.parse(value)
    end
  end

  test "nested validation errors contain each container location once" do
    expression = Expr.new!(:add, [Ref.item(), 1])

    assert {:error, error} =
             Step.new(
               name: "seed",
               action: EchoParamsAction,
               params: %{outer: [%{inner: expression}]}
             )

    assert error.details.path == [:outer, 0, :inner, :operands, 0]

    condition = Condition.eq(Ref.item(), 1)
    assert {:error, error} = Jido.Flow.Expression.validate(%{outer: [condition]}, :flow)
    assert error.details.path == [:outer, 0, :operands, 0]

    assert {:error, error} = Jido.Flow.Expression.validate(%{outer: %{1.5 => :invalid}}, :flow)
    assert error.details.path == [:outer]
  end

  test "missing references in a calculated Choice retain the full error location" do
    expression = Expr.new!(:eq, [Expr.new!(:add, [Ref.input(:missing), 1]), 2])
    assert {:error, error} = Jido.Exec.run(choice_flow(expression))
    assert error.details.phase == :choice_condition
    assert error.details.node == "route"
    assert error.details.option == "yes"
    assert error.details.path == [:missing]
    assert error.details.expression_path == [:operands, 0, :operands, 0]
    assert error.details.retry == false
  end

  test "invalid stored operation names retain Choice and Iterate JSON locations" do
    expression = Expr.new!(:eq, [Expr.new!(:add, [1, 1]), 2])
    invalid = %{"$expr" => %{"operator" => "unknown", "operands" => []}}

    for {flow, path} <- [
          {choice_flow(expression),
           ["components", Access.at(0), "options", Access.at(0), "condition"]},
          {iterator_flow(expression), ["components", Access.at(0), "completion"]}
        ] do
      assert {:ok, document, registry} = Codec.encode(flow)
      assert {:error, error} = Codec.decode(put_in(document, path, invalid), registry)

      assert error.details.path ==
               if(match?(%Choice{}, hd(flow.components)),
                 do: ["components", 0, "options", 0, "condition", "$expr", "operator"],
                 else: ["components", 0, "completion", "$expr", "operator"]
               )
    end
  end

  test "canonical operations preserve Flow string and map-key rules" do
    for data <- [<<255>>, %{nil => 1}, %{-1 => 1}, %{<<255>> => 1}] do
      expression = Expr.new!(:eq, [data, data])
      assert :ok = Expr.validate(expression)

      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
               Jido.Flow.Expression.validate(expression)

      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
               Step.new(name: "seed", action: EchoParamsAction, params: %{nested: expression})

      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
               Condition.new(:eq, [data, data])
    end
  end

  test "skipped mixed operations still validate Flow data and reference scopes" do
    for {outer, inner} <- [{Expr, Condition}, {Condition, Expr}],
        data <- [Ref.item(), <<255>>, %{nil => 1}, %{-1 => 1}] do
      expression =
        struct!(outer,
          operator: :all,
          operands: [false, struct!(inner, operator: :eq, operands: [data, 1])]
        )

      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{} = error} =
               Condition.validate(expression, :flow)

      assert error.details.path == [:operands, 1, :operands, 0]
    end
  end

  test "invalid result names retain their complete normalization path" do
    reference = Ref.result("")

    for {outer, inner} <- [{Expr, Condition}, {Condition, Expr}] do
      expression =
        struct!(outer,
          operator: :eq,
          operands: [struct!(inner, operator: :eq, operands: [reference, 1]), true]
        )

      assert {:error, error} = Condition.new(expression)
      assert Exception.message(error) == "Action name cannot be blank."
      assert error.details.path == [:operands, 0, :operands, 0]

      assert {:error, error} =
               Step.new(name: "seed", action: EchoParamsAction, params: %{outer: [expression]})

      assert error.details.path == [:outer, 0, :operands, 0, :operands, 0]
    end

    assert {:error, error} = Jido.Flow.Expression.normalize(%{outer: [reference]})
    assert error.details.path == [:outer, 0]
  end

  test "legacy and current stored arity errors retain their JSON tag paths" do
    assert {:ok, document, registry} = Codec.encode(choice_flow(Condition.eq(1, 1)))
    location = ["components", Access.at(0), "options", Access.at(0), "condition"]

    for {version, tag} <- [{1, "$condition"}, {2, "$condition"}, {2, "$expr"}],
        {operator, operands} <- [{"eq", [1]}, {"not", []}, {"all", []}] do
      invalid = %{
        tag => %{
          "operator" => "not",
          "operands" => [%{tag => %{"operator" => operator, "operands" => operands}}]
        }
      }

      invalid_document = document |> Map.put("version", version) |> put_in(location, invalid)

      assert {:error, error} =
               Codec.decode(JSON.decode!(JSON.encode!(invalid_document)), registry)

      assert error.details.reason == :invalid_arity

      assert error.details.path == [
               "components",
               0,
               "options",
               0,
               "condition",
               tag,
               "operands",
               0,
               tag
             ]
    end
  end

  defp nested_negate(count),
    do: Enum.reduce(1..count, 1, fn _, value -> Expr.new!(:negate, [value]) end)

  defp output_flow(value),
    do:
      Flow.new!(
        name: "expression_boundary",
        components: [Step.new!(name: "seed", action: EchoParamsAction)],
        output: value
      )

  defp choice_flow(condition) do
    choice =
      Choice.new!(
        name: "route",
        options: [Builder.option("yes", condition, EchoParamsAction, %{selected: true})],
        fallback: [action: EchoParamsAction, params: %{selected: false}]
      )

    Flow.new!(name: "expression_boundary", components: [choice], output: Ref.result("route"))
  end

  defp iterator_flow(condition) do
    iterator =
      Iterate.new!(
        name: "loop",
        action: EchoParamsAction,
        state: [schema: [], initial: %{}, update: %{}],
        completion: condition,
        max_iterations: 1
      )

    Flow.new!(name: "expression_boundary", components: [iterator], output: Ref.result("loop"))
  end

  defp module_flow(module, source) do
    body =
      quote do
        use Jido.Flow, name: "expression_boundary"

        flow do
          step "seed", action: unquote(EchoParamsAction), params: %{}
          output unquote(source)
        end
      end

    Module.create(module, body, Macro.Env.location(__ENV__))
    module.flow()
  end
end
