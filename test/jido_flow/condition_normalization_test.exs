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

  test "legacy trees and helpers use the same Expr model and version-two writer" do
    first = %Condition{operator: :eq, operands: [Ref.input(:score), 1]}
    second = %Condition{operator: :neq, operands: [Ref.input(:score), 2]}

    condition = %Condition{
      operator: :all,
      operands: [first, %Condition{operator: :not, operands: [second]}]
    }

    canonical =
      Expr.new!(:all, [
        Expr.new!(:eq, first.operands),
        Expr.new!(:not, [Expr.new!(:neq, second.operands)])
      ])

    assert {:ok, ^canonical} = Condition.new(condition)
    assert {:ok, ^canonical} = Condition.validate(condition, :flow)
    assert Condition.all([Condition.eq(Ref.input(:score), 1), Condition.not(second)]) == canonical

    assert {:ok, ^canonical} =
             Expression.parse_condition(
               quote(do: all([eq(input(:score), 1), not neq(input(:score), 2)]))
             )

    flow = choice_flow(condition)
    assert choice_flow(canonical) == flow
    assert builder_flow(condition) == flow
    assert round_trip(flow, 2) == flow
    assert Jido.Exec.run(flow, %{score: 1}) == {:ok, %{selected: false}}
  end

  test "version one and two legacy documents read into one current operation format" do
    flow =
      choice_flow(
        Expr.new!(:all, [
          Expr.new!(:eq, [Ref.input(:score), 1.0]),
          Expr.new!(:not, [Expr.new!(:eq, [Ref.input(:score), 2])])
        ])
      )

    assert {:ok, document, registry} = Codec.encode(flow)

    for version <- [1, 2] do
      legacy = document |> legacy_document() |> Map.put("version", version)
      assert {:ok, ^flow} = Codec.decode(JSON.decode!(JSON.encode!(legacy)), registry)
      assert {:ok, ^document} = Codec.encode(flow, registry)
      assert Jido.Exec.run(flow, %{score: 1}) == {:ok, %{selected: true}}
      assert {:ok, %{version: 2}} = Flow.semantic_identity(flow)
    end
  end

  test "Condition helpers share Expr short-circuit and strict Boolean rules" do
    for {operator, operands, expected} <- [
          {:all, [false, 1], {:ok, false}},
          {:any, [true, nil], {:ok, true}},
          {:not, [1], :error},
          {:all, [true, :not_a_condition], :error}
        ] do
      expression = Expr.new!(operator, operands)
      assert {:ok, ^expression} = Condition.new(operator, operands)

      assert {:ok, ^expression} =
               Condition.validate(%Condition{operator: operator, operands: operands}, :flow)

      case expected do
        :error ->
          assert {:error, error} = Jido.Exec.run(choice_flow(expression))
          assert error.details.reason == :invalid_boolean_operand

        {:ok, value} ->
          assert Jido.Exec.run(choice_flow(expression)) == {:ok, %{selected: value}}
      end
    end
  end

  test "legacy and canonical operation trees share all construction limits" do
    cases = [
      {Enum.reduce(1..65, true, fn _, child -> %Condition{operator: :not, operands: [child]} end),
       :max_depth},
      {%Condition{
         operator: :all,
         operands: List.duplicate(%Condition{operator: :eq, operands: [1, 1]}, 4_000)
       }, :max_nodes},
      {%Condition{operator: :eq, operands: [String.duplicate("x", 1_048_577), ""]},
       :max_binary_bytes},
      {%Condition{operator: :eq, operands: [Bitwise.bsl(1, 4096), 0]}, :max_integer_bits}
    ]

    for {legacy, reason} <- cases do
      assert {:error, error} = Condition.new(legacy)
      assert error.details.reason == reason
      assert {:error, error} = Jido.Flow.Expression.normalize(%{nested: legacy})
      assert error.details.reason == reason
    end
  end

  test "legacy stored conditions use Expr limits before any Action executes" do
    flow = choice_flow(Condition.eq(1, 1))
    assert {:ok, document, registry} = Codec.encode(flow)
    condition_path = ["components", Access.at(0), "options", Access.at(0), "condition"]

    for version <- [1, 2],
        {tag, reason} <- [
          {%{"operator" => "eq", "operands" => [String.duplicate("x", 1_048_577), ""]},
           :max_binary_bytes},
          {%{"operator" => "eq", "operands" => [Bitwise.bsl(1, 4096), 0]}, :max_integer_bits},
          {%{
             "operator" => "all",
             "operands" =>
               List.duplicate(
                 %{"$condition" => %{"operator" => "eq", "operands" => [1, 1]}},
                 4_000
               )
           }, :max_nodes}
        ] do
      legacy =
        document |> Map.put("version", version) |> put_in(condition_path, %{"$condition" => tag})

      assert {:error, %InvalidDefinitionError{} = error} = Codec.decode(legacy, registry)
      assert error.details.reason == reason
    end
  end

  test "legacy input and helpers keep one runtime budget for resolved data" do
    legacy = %Condition{operator: :eq, operands: [Ref.input(:data), Ref.input(:data)]}
    canonical = Expr.new!(:eq, legacy.operands)

    for expression <- [legacy, canonical, Condition.eq(Ref.input(:data), Ref.input(:data))] do
      for flow <- [choice_flow(expression), iterator_flow(expression), output_flow(expression)] do
        assert {:error, error} = Jido.Exec.run(flow, %{data: String.duplicate("x", 300_000)})
        assert error.details.reason == :max_binary_bytes
        assert error.details.retry == false
      end
    end
  end

  test "legacy reference names normalize through nested operation operands once" do
    legacy = %Condition{
      operator: :eq,
      operands: [%Ref{source: :result, component: :seed, path: []}, %{value: 1}]
    }

    assert {:ok, %Expr{operands: [%Ref{component: "seed"}, _]}} = Condition.new(legacy)

    assert {:error, error} =
             Jido.Flow.Expression.normalize(%{
               outer: [
                 %Condition{
                   operator: :not,
                   operands: [%Condition{operator: :add, operands: [1, 1]}]
                 }
               ]
             })

    assert error.details.path == [:outer, 0, :operands, 0]
  end

  defp legacy_document(%{"$expr" => record}), do: %{"$condition" => legacy_document(record)}

  defp legacy_document(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, legacy_document(child)} end)

  defp legacy_document(value) when is_list(value), do: Enum.map(value, &legacy_document/1)
  defp legacy_document(value), do: value

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
