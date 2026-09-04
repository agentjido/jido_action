defmodule JidoActionTest.Flow.ConditionNormalizationTest do
  use ExUnit.Case, async: true

  alias Jido.Expr
  alias Jido.Flow
  alias Jido.Flow.{Builder, Choice, Codec, Condition, Iterate, Ref, Step}
  alias Jido.Flow.DSL.Expression
  alias Jido.Flow.Error.InvalidDefinitionError
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "singleton Boolean conditions have one shape across all authoring forms" do
    cases = [
      {quote(do: all([true])), true, %{}, true},
      {quote(do: all([false])), false, %{}, false},
      {quote(do: all([input(:enabled)])), Ref.input(:enabled), %{enabled: true}, true},
      {quote(do: all([input(:enabled)])), Ref.input(:enabled), %{enabled: false}, false}
    ]

    for {{source, value, input, expected}, index} <- Enum.with_index(cases) do
      expression = Expr.new!(:all, [value])
      assert {:ok, ^expression} = Expression.parse_condition(source)
      assert {:ok, ^expression} = Condition.new(:all, [value])
      assert {:ok, ^expression} = Condition.new(expression)
      assert {:ok, ^expression} = Condition.new(value)
      assert {:ok, ^expression} = Condition.validate(expression, :flow)
      assert {:ok, ^expression} = Condition.validate(Condition.all([value]), :flow)

      assert {:ok, ^expression} =
               Condition.validate(%Condition{operator: :all, operands: [value]}, :flow)

      direct = choice_flow(expression)
      from_dsl = module_flow(Module.concat(__MODULE__, "Singleton#{index}"), source)
      built = builder_flow(Builder.all([value]))
      restored = round_trip(direct, 2)

      for flow <- [from_dsl, built, restored, choice_flow(Condition.all([value]))] do
        assert flow == direct
        assert Flow.semantic_identity(flow) == Flow.semantic_identity(direct)
        assert Jido.Exec.run(flow, input) == {:ok, %{selected: expected}}
      end
    end
  end

  test "nested all, any, and not use the same condition normalization" do
    source =
      quote(do: all([all([true]), any([not all([false]), all([input(:enabled)])])]))

    expression =
      Expr.new!(:all, [
        Expr.new!(:all, [true]),
        Expr.new!(:any, [
          Expr.new!(:not, [Expr.new!(:all, [false])]),
          Expr.new!(:all, [Ref.input(:enabled)])
        ])
      ])

    condition =
      Condition.all([
        Condition.all([true]),
        Condition.any([
          Condition.not(Condition.all([false])),
          Condition.all([Ref.input(:enabled)])
        ])
      ])

    assert {:ok, parsed} = Expression.parse_condition(source)
    assert {:ok, canonical} = Condition.new(expression)
    assert parsed == canonical
    assert condition == canonical
    assert {:ok, ^canonical} = Condition.validate(canonical, :flow)
    direct = choice_flow(expression)

    for flow <- [
          module_flow(Module.concat(__MODULE__, "Nested"), source),
          builder_flow(condition),
          choice_flow(condition),
          round_trip(direct, 2)
        ] do
      assert flow == direct
      assert Flow.semantic_identity(flow) == Flow.semantic_identity(direct)
      assert Jido.Exec.run(flow, %{enabled: false}) == {:ok, %{selected: true}}
    end
  end

  test "portable skipped operands work in Choice, Iterate, and data fields" do
    cases = [
      {quote(do: false and 1), Expr.new!(:all, [false, 1]), false},
      {quote(do: true or nil), Expr.new!(:any, [true, nil]), true},
      {quote(do: false and 1 + 1), Expr.new!(:all, [false, Expr.new!(:add, [1, 1])]), false}
    ]

    for {{source, expression, expected}, index} <- Enum.with_index(cases) do
      assert Jido.Exec.run(output_flow(expression)) == {:ok, %{selected: expected}}
      assert {:ok, condition} = Condition.new(expression)
      assert {:ok, ^condition} = Expression.parse_condition(source)
      direct = choice_flow(expression)

      for flow <- [
            direct,
            module_flow(Module.concat(__MODULE__, "Skipped#{index}"), source),
            builder_flow(expression),
            round_trip(direct, 2)
          ] do
        assert flow == direct
        assert Flow.semantic_identity(flow) == Flow.semantic_identity(direct)
        assert Jido.Exec.run(flow) == {:ok, %{selected: expected}}
      end

      iterator = iterator_flow(Expr.new!(:any, [expression, Ref.state(:done)]))
      iterations = if expected, do: 0, else: 1

      for flow <- [iterator, round_trip(iterator, 2)] do
        assert {:ok, %{iterations: ^iterations}} = Jido.Exec.run(flow)
      end
    end
  end

  test "evaluated non-Boolean operands fail with structured errors in every field" do
    for {source, expression, operator} <- [
          {quote(do: true and 1), Expr.new!(:all, [true, 1]), :all},
          {quote(do: false or nil), Expr.new!(:any, [false, nil]), :any}
        ] do
      assert {:ok, ^expression} = Condition.new(expression)
      assert {:ok, ^expression} = Expression.parse_condition(source)

      for {flow, phase, path} <- [
            {choice_flow(expression), :choice_condition, [:operands, 1]},
            {iterator_flow(expression), :iterate_completion, [:operands, 1]},
            {output_flow(expression), nil, [:selected, :operands, 1]}
          ] do
        assert {:error, error} = Jido.Exec.run(flow)
        assert %Jido.Flow.Error.ExecutionFailureError{} = error
        assert error.details.reason == :invalid_boolean_operand
        assert error.details.operator == operator
        assert Map.get(error.details, :phase) == phase
        assert error.details.expression_path == path
        assert error.details.retry == false
      end
    end
  end

  test "skipped operands still require portable data and valid reference scopes" do
    for expression <- [
          Expr.new!(:all, [false, Ref.item()]),
          Expr.new!(:any, [true, Ref.body_result()]),
          Expr.new!(:all, [false, fn -> true end])
        ] do
      assert {:error, %InvalidDefinitionError{}} = Condition.validate(expression, :flow)
    end

    expression = Expr.new!(:any, [true, Ref.item()])

    assert {:error, %InvalidDefinitionError{}} =
             Condition.validate(expression, :iterate_completion)

    expression = Expr.new!(:all, [false, Ref.result("missing")])

    assert {:error, error} =
             Flow.new(
               name: "unknown_skipped_result",
               components: [choice(expression)],
               output: Ref.result("route")
             )

    assert error.details.component == "missing"
  end

  test "legacy Condition trees keep their exact shape and version-one document" do
    first = %Condition{operator: :eq, operands: [Ref.input(:score), 1]}
    second = %Condition{operator: :neq, operands: [Ref.input(:score), 2]}
    negated = %Condition{operator: :not, operands: [second]}
    group = %Condition{operator: :any, operands: [negated]}
    condition = %Condition{operator: :all, operands: [first, group]}

    assert {:ok, ^condition} = Condition.new(condition)
    assert {:ok, ^condition} = Condition.validate(condition, :flow)

    assert Condition.all([
             Condition.eq(Ref.input(:score), 1),
             Condition.any([Condition.not(second)])
           ]) == condition

    assert {:ok, ^condition} =
             Expression.parse_condition(
               quote(do: all([eq(input(:score), 1), any([not neq(input(:score), 2)])]))
             )

    flow = choice_flow(condition)
    assert round_trip(flow, 1) == flow
    assert Jido.Exec.run(flow, %{score: 1}) == {:ok, %{selected: false}}
  end

  test "legacy Condition constructors still reject raw non-Boolean children" do
    for {operator, operands, path} <- [
          {:all, [false, 1], [1]},
          {:any, [true, nil], [1]},
          {:not, [1], [0]},
          {:all, [Condition.eq(1, 1), :not_a_condition], [1]}
        ] do
      assert {:error, %InvalidDefinitionError{} = error} = Condition.new(operator, operands)

      assert error.message ==
               "flow condition #{inspect(operator)} contains an invalid child condition"

      assert error.details.path == path

      assert {:error, %InvalidDefinitionError{}} =
               Condition.validate(%Condition{operator: operator, operands: operands}, :flow)
    end
  end

  defp choice(condition) do
    Choice.new!(
      name: "route",
      options: [Builder.option("yes", condition, EchoParamsAction, %{selected: true})],
      fallback: [action: EchoParamsAction, params: %{selected: false}]
    )
  end

  defp choice_flow(condition),
    do:
      Flow.new!(
        name: "condition_parity",
        components: [choice(condition)],
        output: Ref.result("route")
      )

  defp builder_flow(condition) do
    {:ok, flow} =
      Builder.new(name: "condition_parity")
      |> Builder.choice(
        "route",
        [Builder.option("yes", condition, EchoParamsAction, %{selected: true})],
        action: EchoParamsAction,
        params: %{selected: false}
      )
      |> Builder.output(Ref.result("route"))
      |> Builder.build()

    flow
  end

  defp module_flow(module, source) do
    body =
      quote do
        use Jido.Flow, name: "condition_parity"

        flow do
          choice "route" do
            option "yes",
              condition: unquote(source),
              action: unquote(EchoParamsAction),
              params: %{selected: true}

            otherwise action: unquote(EchoParamsAction), params: %{selected: false}
          end

          output result("route")
        end
      end

    Module.create(module, body, Macro.Env.location(__ENV__))
    module.flow()
  end

  defp output_flow(expression) do
    Flow.new!(
      name: "condition_output",
      components: [Step.new!(name: "seed", action: EchoParamsAction)],
      output: %{selected: expression}
    )
  end

  defp iterator_flow(completion) do
    iterator =
      Iterate.new!(
        name: "loop",
        action: EchoParamsAction,
        state: [schema: [], initial: %{done: false}, update: %{done: true}],
        completion: completion,
        max_iterations: 1
      )

    Flow.new!(name: "condition_iterator", components: [iterator], output: Ref.result("loop"))
  end

  defp round_trip(flow, version) do
    assert {:ok, document, registry} = Codec.encode(flow)
    assert document["version"] == version
    assert {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    restored
  end
end
