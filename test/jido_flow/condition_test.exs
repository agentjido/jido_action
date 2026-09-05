defmodule JidoActionTest.Flow.ConditionTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Condition
  alias Jido.Flow.Ref

  describe "new/2" do
    test "accepts every closed condition operator" do
      comparisons = [:eq, :neq, :lt, :lte, :gt, :gte, :in]

      for operator <- comparisons do
        assert {:ok, %Jido.Expr{operator: ^operator, operands: [left, right]}} =
                 Condition.new(operator, [Ref.input(:kind), :priority])

        assert left == Ref.input(:kind)
        assert right == :priority
      end

      assert {:ok, %Jido.Expr{operator: :all, operands: [first, second]}} =
               Condition.new(:all, [
                 Condition.eq(Ref.input(:kind), :priority),
                 Condition.not(Condition.neq(Ref.context(:role), :admin))
               ])

      assert first.operator == :eq
      assert second.operator == :not
      assert {:ok, %Jido.Expr{operator: :any}} = Condition.new(:any, [Condition.eq(1, 1)])
      assert {:ok, %Jido.Expr{operator: :not}} = Condition.new(:not, [Condition.eq(1, 1)])
    end

    test "rejects unknown operators and invalid operator arity with paths" do
      assert {:error,
              %InvalidDefinitionError{
                message: "unsupported choice condition operator",
                details: %{path: []}
              }} = Condition.new(:unknown, [1])

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
                 Condition.new(operator, operands)

        assert details.reason == :invalid_arity
        assert details.operator == operator
        assert details.path == []
      end
    end

    test "rejects malformed refs, structs, and predicate functions with Expr paths" do
      assert {:error, %InvalidDefinitionError{message: message, details: details}} =
               Condition.new(:eq, [Ref.input([%{bad: :segment}]), 1])

      assert message == "flow expression contains an invalid reference path"
      assert details.path == [:operands, 0]

      assert {:error, %InvalidDefinitionError{message: message, details: details}} =
               Condition.new(:eq, [~D[2026-01-01], 1])

      assert message == "flow expression contains an unsupported value"
      assert details.path == [:operands, 0]
      assert details.expression == Date

      assert {:error, %InvalidDefinitionError{message: message, details: details}} =
               Condition.new(:eq, [fn -> :predicate end, 1])

      assert message == "invalid Flow expression"
      assert details.path == [:operands, 0]
      assert details.reason == :unsupported_value
    end

    test "exposes every ordering helper and the raising constructor" do
      assert %Jido.Expr{operator: :lte} = Condition.lte(1, 2)
      assert %Jido.Expr{operator: :gt} = Condition.gt(2, 1)
      assert %Jido.Expr{operator: :gte} = Condition.gte(2, 2)
      assert_raise InvalidDefinitionError, fn -> Condition.new!(:eq, [1]) end
      assert {:error, %InvalidDefinitionError{}} = Condition.new(:bad)
    end
  end

  test "collects result dependencies from nested condition operands" do
    condition =
      Condition.all([
        Condition.eq(Ref.result(:classify, :kind), :priority),
        Condition.any([
          Condition.in(Ref.result(:load_tags), ["bulk", "archive"]),
          Condition.not(Condition.neq(Ref.result(:classify, :source), "api"))
        ])
      ])

    assert condition |> Jido.Flow.Expression.result_refs() |> Enum.uniq() |> Enum.sort() ==
             ["classify", "load_tags"]
  end
end
