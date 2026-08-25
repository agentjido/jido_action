defmodule JidoActionTest.Flow.ConditionTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.Condition
  alias Jido.Flow.Ref

  describe "new/2" do
    test "accepts every closed condition operator" do
      comparisons = [:eq, :neq, :lt, :lte, :gt, :gte, :in]

      for operator <- comparisons do
        assert {:ok, %Condition{operator: ^operator, operands: [left, right]}} =
                 Condition.new(operator, [Ref.input(:kind), :priority])

        assert left == Ref.input(:kind)
        assert right == :priority
      end

      assert {:ok, %Condition{operator: :all, operands: [first, second]}} =
               Condition.new(:all, [
                 Condition.eq(Ref.input(:kind), :priority),
                 Condition.not(Condition.neq(Ref.context(:role), :admin))
               ])

      assert first.operator == :eq
      assert second.operator == :not
      assert {:ok, %Condition{operator: :any}} = Condition.new(:any, [Condition.eq(1, 1)])
      assert {:ok, %Condition{operator: :not}} = Condition.new(:not, [Condition.eq(1, 1)])
    end

    test "rejects unknown operators and invalid operator arity with paths" do
      cases = [
        {:unknown, [1], "unsupported choice condition operator"},
        {:eq, [1], "choice condition :eq must have exactly 2 operands"},
        {:all, [], "choice condition :all must have at least 1 condition"},
        {:not, [Condition.eq(1, 1), Condition.eq(2, 2)],
         "choice condition :not must have exactly 1 condition"}
      ]

      for {operator, operands, expected_message} <- cases do
        assert {:error, %InvalidInputError{message: ^expected_message, details: details}} =
                 Condition.new(operator, operands)

        assert details.path == []
      end
    end

    test "returns a validation error for improper operands" do
      assert {:error,
              %InvalidInputError{
                message: "choice condition operands must be a proper list",
                details: %{path: []}
              }} = Condition.new(:eq, [1 | :tail])
    end

    test "rejects invalid nested conditions, malformed refs, structs, and predicate functions" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Condition.new(:all, [Condition.eq(1, 1), :not_a_condition])

      assert message == "choice condition :all contains an invalid child condition"
      assert details.path == [1]

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Condition.new(:eq, [Ref.input([%{bad: :segment}]), 1])

      assert message == "choice condition contains invalid ref path"
      assert details.path == [0]

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Condition.new(:eq, [Date.utc_today(), 1])

      assert message == "choice condition contains unsupported expression"
      assert details.path == [0]
      assert details.expression == Date

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Condition.new(:eq, [fn -> :predicate end, 1])

      assert message == "choice condition contains unsupported expression"
      assert details.path == [0]
      assert details.expression == Function
    end

    test "exposes every ordering helper and the raising constructor" do
      assert %Condition{operator: :lte} = Condition.lte(1, 2)
      assert %Condition{operator: :gt} = Condition.gt(2, 1)
      assert %Condition{operator: :gte} = Condition.gte(2, 2)

      assert_raise InvalidInputError, fn -> Condition.new!(:eq, [1]) end

      assert {:error,
              %InvalidInputError{
                message: "choice condition operands must be a list",
                details: %{path: []}
              }} = Condition.new(:eq, :bad)

      assert {:error,
              %InvalidInputError{message: "choice condition must be a Jido.Flow.Condition"}} =
               Condition.new(:bad)
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

    assert Condition.result_deps(condition) == ["classify", "load_tags"]
  end
end
