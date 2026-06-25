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
      }
    )
    |> Syntax.step(
      :double,
      Multiply,
      %{
        value: Syntax.result(:add_one, :value),
        amount: Syntax.value(2)
      }
    )
    |> Syntax.return(Syntax.result(:double, :value))
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
      }
    )
    |> Builder.step(
      :double,
      Multiply,
      %{
        value: Builder.result(:add_one, :value),
        amount: Builder.value(2)
      }
    )
    |> Builder.return(Builder.result(:double, :value))
  end

  def math_source do
    """
    flow do
      step :add_one, JidoTest.TestActions.Add, %{value: input(:value), amount: value(1)}
      step :double, JidoTest.TestActions.Multiply, %{value: result(:add_one, :value), amount: value(2)}
      return result(:double, :value)
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
