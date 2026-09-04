defmodule Jido.ExprTest do
  use ExUnit.Case, async: true

  import Jido.Expr, only: [expr: 1]

  test "constructs and evaluates a portable calculation" do
    assert {:ok, expression} = Jido.Expr.new(:add, [2, 3])
    assert {:ok, 5} = Jido.Expr.evaluate(expression)
  end

  defmodule Reference do
    defstruct [:key]
  end

  test "standalone macro inserts a prebuilt reference through an explicit variable pin" do
    reference = %Reference{key: :count}
    expression = expr(^reference * 2 + 1)

    assert {:ok, 9} = Jido.Expr.evaluate(expression, resolve: fn ^reference -> {:ok, 4} end)
    assert {:ok, 7} = Jido.Expr.evaluate(expr(2 * 3 + 1))

    for source <- [
          quote(do: Jido.Expr.expr(^System.unique_integer())),
          quote(do: Jido.Expr.expr(value)),
          quote(do: Jido.Expr.expr(System.unique_integer()))
        ] do
      assert_raise Jido.Expr.Error, fn -> Macro.expand_once(source, __ENV__) end
    end
  end

  test "callback failures retain the exact nested expression path" do
    assert {:error, %Jido.Expr.Error{reason: :callback_failure, path: [:answer, :operands, 0]}} =
             Jido.Expr.evaluate(%{answer: Jido.Expr.new!(:add, [%Reference{}, 1])},
               resolve: fn _ -> raise "private" end
             )
  end

  test "the complete operator set has numeric, comparison, and string contracts" do
    cases = [
      {:eq, [1, 1.0], true},
      {:neq, [1, 1.0], false},
      {:lt, [1, 2], true},
      {:lte, [2, 2], true},
      {:gt, ["b", "a"], true},
      {:gte, [2.0, 2], true},
      {:in, [1, [2, 1.0]], true},
      {:in, [1, []], false},
      {:all, [true, true], true},
      {:any, [false, true], true},
      {:not, [false], true},
      {:add, [1, 2.5], 3.5},
      {:subtract, [4, 6], -2},
      {:multiply, [3, 2.0], 6.0},
      {:divide, [3, 2], 1.5},
      {:negate, [2], -2},
      {:div, [-7, 3], -2},
      {:rem, [-7, 3], -1},
      {:min, [1, 1.0], 1},
      {:max, [1.0, 1], 1.0},
      {:abs, [-2.5], 2.5},
      {:concat, ["hello", "!"], "hello!"}
    ]

    assert Enum.sort(Enum.uniq(Enum.map(cases, &elem(&1, 0)))) == Enum.sort(Jido.Expr.operators())

    for {operator, operands, expected} <- cases do
      assert {:ok, actual} = Jido.Expr.evaluate(Jido.Expr.new!(operator, operands))
      assert actual === expected
    end
  end

  test "rejects unknown operators, incorrect arity, and improper operand lists" do
    for {operator, operands, reason} <- [
          {:custom, [], :unknown_operator},
          {:not, [], :invalid_arity},
          {:add, [1], :invalid_arity},
          {:all, [], :invalid_arity},
          {:any, [true | false], :invalid_arity}
        ] do
      assert {:error, %Jido.Expr.Error{reason: ^reason}} = Jido.Expr.new(operator, operands)
      assert_raise Jido.Expr.Error, fn -> Jido.Expr.new!(operator, operands) end
    end
  end

  test "strict type and arithmetic failures have paths without runtime values" do
    for {operator, operands, reason} <- [
          {:all, [true, nil], :invalid_boolean_operand},
          {:not, [1], :invalid_boolean_operand},
          {:lt, [:a, :b], :invalid_ordering_operands},
          {:in, [1, %{secret: "private"}], :invalid_membership_right_operand},
          {:add, ["private", 1], :invalid_numeric_operands},
          {:div, [2.0, 1], :invalid_numeric_operands},
          {:concat, ["private", nil], :invalid_binary_operands},
          {:divide, [2, 0], :division_by_zero},
          {:rem, [2, 0], :division_by_zero},
          {:multiply, [1.0e308, 1.0e308], :arithmetic_error}
        ] do
      assert {:error, %Jido.Expr.Error{reason: ^reason, operator: ^operator} = error} =
               Jido.Expr.evaluate(%{answer: Jido.Expr.new!(operator, operands)})

      assert hd(error.path) == :answer
      refute inspect(error.details) =~ "private"
    end
  end

  test "Boolean evaluation short-circuits while validation visits all operands" do
    reference = %Reference{key: :missing}
    resolver = fn _ -> flunk("skipped operand must not resolve") end

    assert {:ok, false} =
             Jido.Expr.evaluate(Jido.Expr.new!(:all, [false, reference]), resolve: resolver)

    assert {:ok, true} =
             Jido.Expr.evaluate(Jido.Expr.new!(:any, [true, reference]), resolve: resolver)

    assert {:error, %Jido.Expr.Error{reason: :unsupported_value, path: [:operands, 1]}} =
             Jido.Expr.validate(Jido.Expr.new!(:all, [false, reference]))

    assert :ok =
             Jido.Expr.validate(Jido.Expr.new!(:all, [false, reference]),
               validate_leaf: fn ^reference -> :ok end
             )
  end

  test "shared parser supports all syntax, precedence, and legacy aliases" do
    cases = [
      {quote(do: 1 + 2 * 3), 7},
      {quote(do: -(2 - 5)), 3},
      {quote(do: div(-7, 3)), -2},
      {quote(do: rem(-7, 3)), -1},
      {quote(do: min(2, max(1, abs(-3)))), 2},
      {quote(do: 3 / 2), 1.5},
      {quote(do: "a" <> "b" <> "c"), "abc"},
      {quote(do: (1 == 1.0 and not false) or false), true},
      {quote(do: 2 != 3 and 2 < 3 and 2 <= 2 and 3 > 2 and 3 >= 3), true},
      {quote(do: 1 in [1.0, 2]), true},
      {quote(do: all([eq(1, 1), neq(1, 2), lt(1, 2), lte(1, 1), gt(2, 1), gte(2, 2)])), true},
      {quote(do: any([false, true])), true},
      {quote(do: expr(%{items: [1 + 2, nil]})), %{items: [3, nil]}},
      {quote(do: []), []}
    ]

    for {ast, expected} <- cases do
      assert {:ok, expression} = Jido.Expr.parse(ast)
      assert {:ok, actual} = Jido.Expr.evaluate(expression)
      assert actual === expected
    end
  end

  test "a downstream reference DSL uses the identical operator parser and evaluator" do
    parser = fn
      {:field, _, [key]} when is_atom(key) -> {:ok, %Reference{key: key}}
      _ -> :error
    end

    expression =
      Jido.Expr.parse!(quote(do: field(:count) * 2 >= 8 and not field(:paused)),
        leaf_parser: parser
      )

    values = %{count: 4, paused: false}

    assert {:ok, true} =
             Jido.Expr.evaluate(expression,
               resolve: fn %Reference{key: key}, path ->
                 assert is_list(path)
                 Map.fetch(values, key)
               end
             )

    assert :ok =
             Jido.Expr.validate(expression,
               validate_leaf: fn %Reference{}, path ->
                 assert :operands in path
                 :ok
               end
             )

    assert {:ok, %Jido.Expr{operator: :add}} =
             Jido.Expr.parse(quote(do: 1 + 2), leaf_parser: fn _ -> {:ok, :wrong} end)
  end

  test "parser rejects general Elixir without executing it" do
    for ast <- [
          quote(do: System.unique_integer()),
          quote(do: value),
          quote(do: x = 1),
          quote(do: 1 |> abs()),
          quote(do: fn -> 1 end),
          quote(do: ^value),
          quote(do: 1 && 2),
          quote(do: false || true),
          quote(do: !false),
          quote(do: 1 === 1),
          quote(do: 1 !== 1),
          quote(do: 1 ** 2),
          quote(do: round(1.2)),
          quote(do: "hello #{value}"),
          quote(do: [key: 1]),
          quote(do: {1, 2}),
          quote(do: [1 | 2]),
          quote(do: %{key: 1, key: 2}),
          quote(do: all([]))
        ] do
      assert {:error, %Jido.Expr.Error{}} = Jido.Expr.parse(ast)
      assert_raise Jido.Expr.Error, fn -> Jido.Expr.parse!(ast) end
    end

    assert {:error, %Jido.Expr.Error{reason: :duplicate_key}} =
             Jido.Expr.parse(quote(do: %{key: 1, key: 2}))
  end

  test "resolved expression-shaped data is not executed" do
    data = Jido.Expr.new!(:divide, [1, 0])
    reference = %Reference{key: :data}
    assert {:ok, ^data} = Jido.Expr.evaluate(reference, resolve: fn _ -> {:ok, data} end)

    assert {:ok, true} =
             Jido.Expr.evaluate(Jido.Expr.new!(:eq, [reference, reference]),
               resolve: fn _ -> {:ok, self()} end
             )

    assert {:error, %Jido.Expr.Error{reason: :invalid_membership_right_operand}} =
             Jido.Expr.evaluate(Jido.Expr.new!(:in, [1, reference]),
               resolve: fn _ -> {:ok, [1 | 2]} end
             )
  end

  test "limits cover full trees, resolved data, generated output, and comparison work" do
    deep = Enum.reduce(1..8, 0, fn _, child -> [child] end)
    assert {:error, %Jido.Expr.Error{reason: :max_depth}} = Jido.Expr.validate(deep, max_depth: 4)

    assert {:error, %Jido.Expr.Error{reason: :max_nodes}} =
             Jido.Expr.evaluate([1, 2, 3], max_nodes: 3)

    assert {:error, %Jido.Expr.Error{reason: :max_binary_bytes}} =
             Jido.Expr.evaluate(Jido.Expr.new!(:concat, ["abc", "def"]), max_binary_bytes: 8)

    assert {:error, %Jido.Expr.Error{reason: :max_integer_bits}} =
             Jido.Expr.evaluate(Jido.Expr.new!(:multiply, [16, 16]), max_integer_bits: 8)

    assert {:error, %Jido.Expr.Error{reason: :max_integer_bits}} =
             Jido.Expr.validate(256, max_integer_bits: 8)

    assert {:error, %Jido.Expr.Error{reason: :max_nodes}} =
             Jido.Expr.evaluate(%Reference{},
               resolve: fn _ -> {:ok, Enum.to_list(1..10)} end,
               max_nodes: 5
             )

    assert {:error, %Jido.Expr.Error{reason: :max_depth}} =
             Jido.Expr.parse(quote(do: [[[1 + 2]]]), max_depth: 2)
  end

  test "invalid options and invalid host callbacks return structured errors" do
    for options <- [
          [unknown: true],
          [max_depth: 0],
          [max_nodes: -1],
          [max_integer_bits: nil],
          [:bad],
          [resolve: :bad]
        ] do
      assert {:error, %Jido.Expr.Error{reason: :invalid_options}} = Jido.Expr.evaluate(1, options)
    end

    assert {:error, %Jido.Expr.Error{reason: :invalid_callback_return}} =
             Jido.Expr.evaluate(%Reference{}, resolve: fn _ -> :bad end)

    assert {:error, %Jido.Expr.Error{reason: :callback_failure}} =
             Jido.Expr.evaluate(%Reference{}, resolve: fn _ -> raise "private" end)

    assert {:error, :host_error} =
             Jido.Expr.evaluate(%Reference{}, resolve: fn _ -> {:error, :host_error} end)
  end
end
