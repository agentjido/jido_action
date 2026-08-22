defmodule JidoTest.FlowFixtures do
  @moduledoc false

  alias Jido.Flow.Builder
  alias JidoTest.TestActions.{Add, Multiply}

  def math_builder do
    Builder.new(
      name: "math_flow",
      description: "Adds one and doubles the result"
    )
    |> Builder.step(
      "add_one",
      Add,
      %{value: Builder.input(:value), amount: Builder.value(1)}
    )
    |> Builder.step(
      "double",
      Multiply,
      %{value: Builder.result("add_one", :value), amount: Builder.value(2)}
    )
    |> Builder.return(Builder.result("double"))
  end
end
