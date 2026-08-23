defmodule JidoTest.FlowFixtures do
  @moduledoc false

  alias Jido.Flow.{Builder, Registry}
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

  def math_flow! do
    {:ok, flow} = Builder.build(math_builder())
    flow
  end

  def storage_registry do
    Registry.new!(%{
      "action/add/v1" => {:action, Add},
      "action/multiply/v1" => {:action, Multiply},
      "schema/empty/v1" => {:schema, []}
    })
  end
end
