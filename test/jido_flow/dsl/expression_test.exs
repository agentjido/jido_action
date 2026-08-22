defmodule Jido.Flow.DSL.ExpressionTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.DSL.Expression
  alias Jido.Flow.Syntax

  test "lowers the closed Flow expression vocabulary" do
    expression =
      quote do
        %{
          input: input(),
          input_path: input(:id),
          context: context(),
          context_path: context([:request, :id]),
          result: result("loaded"),
          result_path: result("loaded", :id),
          selected: select(result("loaded"), [:customer, :id]),
          item: item(),
          item_path: item(:price),
          item_index: item_index(),
          item_id: item_id(),
          accumulator: accumulator(),
          accumulator_path: accumulator(:total),
          state: state(),
          state_path: state(:status),
          iteration_index: iteration_index(),
          body_result: body_result(),
          body_result_path: body_result(:status),
          literal: value(:ok),
          nested: [1, true, nil, "value"]
        }
      end

    assert {:ok, parsed} = Expression.parse(expression)
    assert parsed.input == Syntax.input([])
    assert parsed.input_path == Syntax.input(:id)
    assert parsed.context == Syntax.context([])
    assert parsed.context_path == Syntax.context([:request, :id])
    assert parsed.result == Syntax.result("loaded")
    assert parsed.result_path == Syntax.result("loaded", :id)
    assert parsed.selected == Syntax.select(Syntax.result("loaded"), [:customer, :id])
    assert parsed.item == Syntax.item()
    assert parsed.item_path == Syntax.item(:price)
    assert parsed.item_index == Syntax.item_index()
    assert parsed.item_id == Syntax.item_id()
    assert parsed.accumulator == Syntax.accumulator()
    assert parsed.accumulator_path == Syntax.accumulator(:total)
    assert parsed.state == Syntax.state()
    assert parsed.state_path == Syntax.state(:status)
    assert parsed.iteration_index == Syntax.iteration_index()
    assert parsed.body_result == Syntax.body_result()
    assert parsed.body_result_path == Syntax.body_result(:status)
    assert parsed.literal == Syntax.value(:ok)
    assert parsed.nested == Enum.map([1, true, nil, "value"], &Syntax.value/1)
  end

  test "lowers native and function condition forms" do
    native =
      quote do
        input(:kind) in [:priority, :express] and
          not (context(:blocked) == true or input(:total) < 0)
      end

    function =
      quote do
        all([
          eq(input(:kind), :priority),
          any([gte(input(:total), 10), neq(context(:region), "blocked")])
        ])
      end

    assert {:ok, %Syntax.Condition{operator: :all}} = Expression.parse_condition(native)
    assert {:ok, %Syntax.Condition{operator: :all}} = Expression.parse_condition(function)
  end

  test "rejects executable expressions, keyword data, and invalid conditions" do
    assert {:error, error} = Expression.parse(quote(do: Date.utc_today()))
    assert Exception.message(error) =~ "unsupported Flow expression"

    assert {:error, error} = Expression.parse(status: :ready)
    assert Exception.message(error) =~ "unsupported Flow expression"

    assert {:error, error} = Expression.parse_condition(quote(do: input(:ready)))
    assert Exception.message(error) =~ "unsupported Flow condition"
  end
end
