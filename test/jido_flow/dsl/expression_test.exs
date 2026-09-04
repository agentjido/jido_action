defmodule JidoActionTest.Flow.DSL.ExpressionTest do
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
    assert parsed.literal == :ok
    assert parsed.nested == [1, true, nil, "value"]
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

  test "lowers empty list literals without changing reference paths or keyword rejection" do
    assert {:ok, []} = Expression.parse(quote(do: []))
    assert {:ok, []} = Expression.parse(quote(do: value([])))

    assert {:ok, %{items: [[], %{values: []}]}} =
             Expression.parse(quote(do: %{items: [[], %{values: []}]}))

    assert {:ok, %{items: []}} = Expression.parse(%{items: []})
    assert {:ok, ref} = Expression.parse(quote(do: input([])))
    assert ref == Ref.input([])
    assert {:ok, ref} = Expression.parse(quote(do: result("step", [])))
    assert ref == Ref.result("step")
    assert {:error, _error} = Expression.parse(quote(do: [items: []]))
  end

  test "lowers empty lists in comparison operands" do
    assert {:ok, %Condition{operator: :eq, operands: [ref, []]}} =
             Expression.parse_condition(quote(do: input(:items) == []))

    assert ref == Ref.input(:items)

    assert {:ok, %Condition{operator: :in, operands: [1, []]}} =
             Expression.parse_condition(quote(do: 1 in []))
  end

  test "rejects executable expressions, keyword data, and invalid conditions" do
    assert {:error, error} = Expression.parse(quote(do: Date.utc_today()))

    assert Exception.message(error) ==
             "unsupported Flow expression: Date.utc_today(); use a Flow reference, literal, map, or list"

    assert {:error, error} = Expression.parse(status: :ready)
    assert Exception.message(error) =~ "unsupported Flow expression"

    assert {:error, error} = Expression.parse_condition(quote(do: :ready))

    assert Exception.message(error) ==
             "unsupported Flow condition: :ready; use a Boolean reference, Boolean literal, or Flow condition"
  end

  test "rejects assignment, pattern matching, and pipes as declarative data" do
    for expression <- [
          quote(do: selected = input(:value)),
          quote(do: %{value: selected} = input(:payload)),
          quote(do: input(:value) |> Integer.to_string())
        ] do
      assert {:error, error} = Expression.parse(expression)
      assert Exception.message(error) =~ "use a Flow reference, literal, map, or list"
    end
  end

  test "accepts canonical references and literal maps" do
    ref = Ref.result("loaded", :value)
    assert {:ok, ^ref} = Expression.parse(ref)

    assert {:ok, %{status: :ready}} = Expression.parse(quote(do: value(%{status: :ready})))

    assert {:ok, %{status: :ready}} = Expression.parse(%{status: :ready})
  end

  test "lowers every comparison spelling" do
    for {expression, operator} <- [
          {quote(do: input(:left) != input(:right)), :neq},
          {quote(do: input(:left) <= input(:right)), :lte},
          {quote(do: input(:left) > input(:right)), :gt},
          {quote(do: input(:left) >= input(:right)), :gte},
          {quote(do: lt(input(:left), input(:right))), :lt},
          {quote(do: lte(input(:left), input(:right))), :lte},
          {quote(do: gt(input(:left), input(:right))), :gt}
        ] do
      assert {:ok, %Condition{operator: ^operator}} = Expression.parse_condition(expression)
    end
  end

  test "rejects invalid result names, paths, selections, literals, and duplicate maps" do
    invalid = [
      quote(do: result(nil)),
      quote(do: input(1.5)),
      quote(do: select(%{value: 1}, :path)),
      quote(do: value(self())),
      quote(do: %{value: 1, value: 2})
    ]

    for expression <- invalid do
      assert {:error, error} = Expression.parse(expression)

      assert Enum.any?(
               ["unsupported Flow expression", "duplicate Flow map key"],
               &String.contains?(Exception.message(error), &1)
             )
    end
  end
end
