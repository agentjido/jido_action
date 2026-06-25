defmodule JidoTest.FlowFixtures do
  @moduledoc false

  alias Jido.Flow.Builder
  alias Jido.Flow.Syntax
  alias JidoTest.TestActions.{Add, Multiply}

  def math_syntax do
    Syntax.new(
      name: "math_flow",
      description: "Adds one and doubles the result"
    )
    |> Syntax.step(
      :add_one,
      Add,
      %{
        value: Syntax.input(:value),
        amount: Syntax.value(1)
      },
      bind: :added
    )
    |> Syntax.step(
      :double,
      Multiply,
      %{
        value: Syntax.var(:added, :value),
        amount: Syntax.value(2)
      },
      bind: :doubled
    )
    |> Syntax.return(Syntax.var(:doubled, :value))
  end

  def math_builder do
    Builder.new(
      name: "math_flow",
      description: "Adds one and doubles the result"
    )
    |> Builder.step(
      :add_one,
      Add,
      %{
        value: Builder.input(:value),
        amount: Builder.value(1)
      },
      bind: :added
    )
    |> Builder.step(
      :double,
      Multiply,
      %{
        value: Builder.var(:added, :value),
        amount: Builder.value(2)
      },
      bind: :doubled
    )
    |> Builder.return(Builder.var(:doubled, :value))
  end

  def math_source do
    """
    flow do
      step :add_one, JidoTest.TestActions.Add, %{value: input(:value), amount: value(1)}, bind: :added
      step :double, JidoTest.TestActions.Multiply, %{value: var(:added, :value), amount: value(2)}, bind: :doubled
      return var(:doubled, :value)
    end
    """
  end

  def math_canonical_map do
    %{
      type: :flow,
      name: "math_flow",
      description: "Adds one and doubles the result",
      schema: [],
      output_schema: [],
      nodes: [
        %{
          name: :add_one,
          action: Add,
          input: %{
            value: %{type: :input, path: [:value]},
            amount: %{type: :value, value: 1}
          },
          deps: []
        },
        %{
          name: :double,
          action: Multiply,
          input: %{
            value: %{type: :result, node: :add_one, path: [:value]},
            amount: %{type: :value, value: 2}
          },
          deps: [:add_one]
        }
      ],
      return: %{type: :result, node: :double, path: [:value]}
    }
  end
end
