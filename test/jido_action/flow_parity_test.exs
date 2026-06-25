defmodule Jido.FlowParityTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow.Builder
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  test "macro and builder math flows produce equal canonical maps" do
    module = unique_module("MacroParityMathFlow")

    create_module(
      module,
      quote do
        use Jido.Flow,
          name: "math_flow",
          description: "Adds one and doubles the result"

        flow do
          step(:add_one, unquote(Add), %{value: input(:value), amount: value(1)}, bind: :added)

          step(:double, unquote(Multiply), %{value: var(:added, :value), amount: value(2)},
            bind: :doubled
          )

          return(var(:doubled, :value))
        end
      end
    )

    assert {:ok, builder_flow} = Builder.build(FlowFixtures.math_builder())
    assert module.to_map() == Jido.Flow.to_map(builder_flow)
  end
end
