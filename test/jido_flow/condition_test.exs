defmodule JidoActionTest.Flow.ConditionTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Expr
  alias Jido.Flow.Builder
  alias Jido.Flow.Expression
  alias Jido.Flow.Ref

  describe "condition/2" do
    test "accepts every closed condition operator" do
      comparisons = [:eq, :neq, :lt, :lte, :gt, :gte, :in]

      for operator <- comparisons do
        assert {:ok, %Expr{operator: ^operator, operands: [left, right]}} =
                 Expression.condition(
                   %Expr{operator: operator, operands: [Ref.input(:kind), :priority]},
                   :any
                 )

        assert left == Ref.input(:kind)
        assert right == :priority
      end

      assert {:ok, %Expr{operator: :all, operands: [first, second]}} =
               Expression.condition(
                 %Expr{
                   operator: :all,
                   operands: [
                     Expr.new!(:eq, [Ref.input(:kind), :priority]),
                     Expr.new!(:not, [Expr.new!(:neq, [Ref.context(:role), :admin])])
                   ]
                 },
                 :any
               )

      assert first.operator == :eq
      assert second.operator == :not

      assert {:ok, %Expr{operator: :any}} =
               Expression.condition(
                 %Expr{operator: :any, operands: [Expr.new!(:eq, [1, 1])]},
                 :any
               )

      assert {:ok, %Expr{operator: :not}} =
               Expression.condition(
                 %Expr{operator: :not, operands: [Expr.new!(:eq, [1, 1])]},
                 :any
               )
    end

    test "rejects unknown operators and invalid operator arity with paths" do
      assert {:error,
              %InvalidDefinitionError{
                message: "invalid Flow expression",
                details: %{path: [], reason: :unknown_operator}
              }} =
               Expression.condition(%Expr{operator: :unknown, operands: [1]}, :any)

      for {operator, operands} <- [
            {:eq, [1]},
            {:all, []},
            {:not, [true, false]},
            {:eq, [1 | :tail]},
            {:all, [true | :tail]},
            {:eq, :bad}
          ] do
        assert {:error,
                %InvalidDefinitionError{message: "invalid Flow expression", details: details}} =
                 Expression.condition(
                   %Expr{operator: operator, operands: operands},
                   :any
                 )

        assert details.reason == :invalid_arity
        assert details.operator == operator
        assert details.path == []
      end
    end

    test "rejects malformed refs, structs, and predicate functions with Expr paths" do
      assert {:error, %InvalidDefinitionError{message: message, details: details}} =
               Expression.condition(
                 %Expr{operator: :eq, operands: [Ref.input([%{bad: :segment}]), 1]},
                 :any
               )

      assert message == "flow expression contains an invalid reference path"
      assert details.path == [:operands, 0]

      assert {:error, %InvalidDefinitionError{message: message, details: details}} =
               Expression.condition(
                 %Expr{operator: :eq, operands: [~D[2026-01-01], 1]},
                 :any
               )

      assert message == "flow expression contains an unsupported value"
      assert details.path == [:operands, 0]
      assert details.expression == Date

      assert {:error, %InvalidDefinitionError{message: message, details: details}} =
               Expression.condition(
                 %Expr{operator: :eq, operands: [fn -> :predicate end, 1]},
                 :any
               )

      assert message == "invalid Flow expression"
      assert details.path == [:operands, 0]
      assert details.reason == :unsupported_value
    end

    test "Builder helpers validate Flow operands before returning an Expr" do
      for operator <- [:eq, :neq, :lt, :lte, :gt, :gte, :in] do
        assert %Expr{operator: ^operator} = apply(Builder, operator, [1, 2])
      end

      assert %Expr{operator: :all} = Builder.all([true])
      assert %Expr{operator: :any} = Builder.any([false])
      assert %Expr{operator: :not} = Builder.not(true)
      assert_raise InvalidDefinitionError, fn -> Builder.all([]) end
      assert_raise InvalidDefinitionError, fn -> Builder.eq(~D[2026-01-01], 1) end
      assert {:error, %InvalidDefinitionError{}} = Expression.condition(:bad, :any)
    end
  end

  test "collects result dependencies from nested condition operands" do
    condition =
      Expr.new!(:all, [
        Expr.new!(:eq, [Ref.result(:classify, :kind), :priority]),
        Expr.new!(:any, [
          Expr.new!(:in, [Ref.result(:load_tags), ["bulk", "archive"]]),
          Expr.new!(:not, [Expr.new!(:neq, [Ref.result(:classify, :source), "api"])])
        ])
      ])

    assert condition |> Jido.Flow.Expression.result_refs() |> Enum.uniq() |> Enum.sort() ==
             ["classify", "load_tags"]
  end
end
