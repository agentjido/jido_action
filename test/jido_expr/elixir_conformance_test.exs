defmodule Jido.Expr.ElixirConformanceTest do
  use ExUnit.Case, async: true

  require Jido.Expr
  alias Jido.Expr
  alias Jido.Flow.{Codec, Ref, Step}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  # Each entry owns one accepted spelling and arity. Alias entries give the
  # native expression that defines their meaning.
  @syntax [
    {:==, 2, :eq, "1 == 1.0", "1 == 1.0"},
    {:!=, 2, :neq, "1 != 1.0", "1 != 1.0"},
    {:<, 2, :lt, "1 < :a", "1 < :a"},
    {:<=, 2, :lte, "[1] <= [1.0]", "[1] <= [1.0]"},
    {:>, 2, :gt, "%{a: 1} > []", "%{a: 1} > []"},
    {:>=, 2, :gte, "nil >= false", "nil >= false"},
    {:in, 2, :in, "1 in [1.0]", "1 in [1.0]"},
    {:and, 2, :and, "true and 123", "true and 123"},
    {:or, 2, :or, "false or \"fallback\"", "false or \"fallback\""},
    {:not, 1, :not, "not false", "not false"},
    {:+, 2, :add, "1 + 2.5", "1 + 2.5"},
    {:-, 2, :subtract, "1 - 2", "1 - 2"},
    {:-, 1, :negate, "-2.5", "-2.5"},
    {:*, 2, :multiply, "2 * 1.5", "2 * 1.5"},
    {:/, 2, :divide, "3 / 2", "3 / 2"},
    {:<>, 2, :concat, "\"a\" <> \"b\"", "\"a\" <> \"b\""},
    {:div, 2, :div, "div(-7, 3)", "div(-7, 3)"},
    {:rem, 2, :rem, "rem(-7, 3)", "rem(-7, 3)"},
    {:min, 2, :min, "min(:a, 1)", "min(:a, 1)"},
    {:max, 2, :max, "max([1], [1.0])", "max([1], [1.0])"},
    {:abs, 1, :abs, "abs(-2.5)", "abs(-2.5)"},
    {:eq, 2, :eq, "eq(1, 1.0)", "1 == 1.0"},
    {:neq, 2, :neq, "neq(1, 1.0)", "1 != 1.0"},
    {:lt, 2, :lt, "lt(:a, :b)", ":a < :b"},
    {:lte, 2, :lte, "lte([], :a)", "[] <= :a"},
    {:gt, 2, :gt, "gt(\"a\", 1)", "\"a\" > 1"},
    {:gte, 2, :gte, "gte(%{}, [])", "%{} >= []"},
    {:all, 1, :all, "all([true, false])", "true and false"},
    {:any, 1, :any, "any([false, true])", "false or true"}
  ]

  test "every supported spelling and canonical operator has a reference case" do
    assert Enum.sort(Expr.Parser.syntax()) ==
             Enum.sort(Enum.map(@syntax, fn {name, arity, _, _, _} -> {name, arity} end))

    assert Enum.sort(Expr.operators()) ==
             @syntax |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()
  end

  for {name, arity, operator, source, native_source} <- @syntax do
    test "#{name}/#{arity} agrees through source, macro, and canonical data" do
      ast = Code.string_to_quoted!(unquote(source))
      assert {:ok, expression} = Expr.parse(ast)
      assert expression.operator == unquote(operator)
      assert Expr.new!(expression.operator, expression.operands) == expression
      macro_ast = quote do: Jido.Expr.expr(unquote(ast))
      {expanded, []} = macro_ast |> Macro.expand_once(__ENV__) |> Code.eval_quoted()
      assert expanded == expression
      assert_native(expression, Code.string_to_quoted!(unquote(native_source)))
    end
  end

  @edges [
    "2 + 3 * 4",
    "(2 + 3) * 4",
    "8 - 3 - 2",
    "8 / 4 / 2",
    "-(-2)",
    "not false and false or true",
    "true or false and false",
    "true or (false and false)",
    "(true and 123) and false",
    "true and (123 and false)",
    "false and (123 and false)",
    "(false or 123) or true",
    "false or (123 or true)",
    "true or (123 or true)",
    "false and 1 / 0",
    "true or 1 / 0",
    "true and nil",
    "false or nil",
    "nil and true",
    "1 or false",
    "not 1",
    "[1] in [[1.0]]",
    "%{a: 1} in [%{a: 1.0}]",
    "1 in [1.0, 1]",
    "1 in []",
    "1 in 1",
    "min(1, 1.0)",
    "min(1.0, 1)",
    "max(1, 1.0)",
    "max(1.0, 1)",
    "min(%{a: 1}, %{a: 1.0})",
    "div(7, -3)",
    "rem(7, -3)",
    "div(-7, -3)",
    "rem(-7, -3)",
    "1 / 0",
    "1 / 0.0",
    "div(1, 0)",
    "rem(1, 0)",
    "div(1.0, 2)",
    "1 + :a",
    "abs(:a)",
    "-:a",
    "1.0e308 * 1.0e308",
    "\"a\" <> 1"
  ]

  for source <- @edges do
    test "native edge: #{source}" do
      ast = Code.string_to_quoted!(unquote(source))

      assert {:ok, expression} = Expr.parse(ast)
      assert_native(expression, ast)
    end
  end

  test "ordering and selection match native term order across the supported data set" do
    values = [
      nil,
      false,
      :a,
      -1,
      0,
      1,
      1.0,
      2.5,
      "",
      "a",
      [],
      [1],
      [1.0],
      %{},
      %{a: 1},
      %{a: 1.0}
    ]

    for left <- values, right <- values, operator <- [:<, :<=, :>, :>=, :min, :max, :==, :!=] do
      ast = {operator, [], [Macro.escape(left), Macro.escape(right)]}
      assert {:ok, expression} = Expr.parse(ast)
      assert_native(expression, ast)
    end
  end

  test "binary Boolean operators skip only the unneeded resolver in operand order" do
    parent = self()
    left = Ref.input(:left)
    right = Ref.input(:right)

    resolver = fn ref ->
      send(parent, ref.path)
      if ref == left, do: {:ok, true}, else: {:error, :missing}
    end

    assert {:ok, true} = Expr.evaluate(Expr.new!(:or, [left, right]), resolve: resolver)
    assert_received [:left]
    refute_received [:right]
    assert {:error, :missing} = Expr.evaluate(Expr.new!(:and, [left, right]), resolve: resolver)
    assert_received [:left]
    assert_received [:right]
    assert :ok = Expr.validate(Expr.new!(:or, [left, right]), validate_leaf: fn _ -> :ok end)
  end

  test "all and any retain their strict Boolean helper contract" do
    for {name, first} <- [{:all, true}, {:any, false}] do
      assert {:error, %Expr.Error{reason: :invalid_boolean_operand}} =
               Expr.evaluate(Expr.new!(name, [first, 123]))
    end
  end

  test "unsupported source never becomes a general evaluator" do
    for source <- [
          "1 === 1.0",
          "true && 1",
          "false || 1",
          "!false",
          "+1",
          "1..2",
          "x = 1",
          "1 |> abs()",
          "System.unique_integer()",
          "fn -> 1 end",
          "if true, do: 1",
          "1 in [1 | 2]",
          "\"a\#{1}\""
        ] do
      assert {:error, %Expr.Error{}} = source |> Code.string_to_quoted!() |> Expr.parse()
    end
  end

  test "stored beta documents keep their version and use the corrected rules" do
    assert Expr.expr(true and 123) == Expr.new!(:and, [true, 123])
    output = %{member: Expr.new!(:in, [1, [1.0]]), value: Expr.new!(:and, [true, 123])}

    flow =
      Jido.Flow.new!(
        name: "native_expr",
        components: [Step.new!(name: "seed", action: EchoParamsAction)],
        output: output
      )

    assert {:ok, document, registry} = Codec.encode(flow)
    assert document["version"] == 2

    assert {:ok, restored} =
             document |> JSON.encode!() |> JSON.decode!() |> Codec.decode(registry)

    assert {:ok, %{member: false, value: 123}} = Jido.Exec.run(restored)
  end

  defp assert_native(expression, ast) do
    case native(ast) do
      {:ok, expected} ->
        assert {:ok, actual} = Expr.evaluate(expression)
        assert actual === expected, "native mismatch for #{Macro.to_string(ast)}"

      :error ->
        assert {:error, %Expr.Error{}} = Expr.evaluate(expression)
    end
  end

  defp native(ast) do
    {result, _diagnostics} =
      Code.with_diagnostics([log: false], fn ->
        try do
          {value, _} = Code.eval_quoted(ast)
          {:ok, value}
        rescue
          _ -> :error
        end
      end)

    result
  end
end
