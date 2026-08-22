defmodule Jido.Flow.DSL.ExpressionTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.{Condition, Ref}
  alias Jido.Flow.DSL.Expression

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
    assert parsed.input == Ref.input([])
    assert parsed.input_path == Ref.input(:id)
    assert parsed.context == Ref.context([])
    assert parsed.context_path == Ref.context([:request, :id])
    assert parsed.result == Ref.result("loaded")
    assert parsed.result_path == Ref.result("loaded", :id)
    assert parsed.selected == Ref.result("loaded", [:customer, :id])
    assert parsed.item == Ref.item()
    assert parsed.item_path == Ref.item(:price)
    assert parsed.item_index == Ref.item_index()
    assert parsed.item_id == Ref.item_id()
    assert parsed.accumulator == Ref.accumulator()
    assert parsed.accumulator_path == Ref.accumulator(:total)
    assert parsed.state == Ref.state()
    assert parsed.state_path == Ref.state(:status)
    assert parsed.iteration_index == Ref.iteration_index()
    assert parsed.body_result == Ref.body_result()
    assert parsed.body_result_path == Ref.body_result(:status)
    assert parsed.literal == Ref.value(:ok)
    assert parsed.nested == Enum.map([1, true, nil, "value"], &Ref.value/1)
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

    assert {:ok, %Condition{operator: :all}} = Expression.parse_condition(native)
    assert {:ok, %Condition{operator: :all}} = Expression.parse_condition(function)
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
