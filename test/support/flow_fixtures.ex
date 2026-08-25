defmodule JidoActionTest.FlowFixtures do
  @moduledoc false

  alias Jido.Flow.{Builder, Registry}
  alias JidoActionTest.TestActions.{Add, Multiply}

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
    |> Builder.output(Builder.result("double"))
  end

  def math_flow! do
    {:ok, flow} = Builder.build(math_builder())
    flow
  end

  def storage_registry do
    Registry.new!(%{
      "action/add/v1" => {:action, Add},
      "action/multiply/v1" => {:action, Multiply},
      "schema/empty/v1" => {:schema, []},
      "atom/amount/v1" => {:atom, :amount},
      "atom/atom-key/v1" => {:atom, :atom_key},
      "atom/bad/v1" => {:atom, :bad},
      "atom/blocked/v1" => {:atom, :blocked},
      "atom/disabled/v1" => {:atom, :disabled},
      "atom/host/v1" => {:atom, :host},
      "atom/id/v1" => {:atom, :id},
      "atom/items/v1" => {:atom, :items},
      "atom/key/v1" => {:atom, :key},
      "atom/kind/v1" => {:atom, :kind},
      "atom/line/v1" => {:atom, :line},
      "atom/payload/v1" => {:atom, :payload},
      "atom/ready/v1" => {:atom, :ready},
      "atom/request/v1" => {:atom, :request},
      "atom/result/v1" => {:atom, :result},
      "atom/selected/v1" => {:atom, :selected},
      "atom/source/v1" => {:atom, :source},
      "atom/state/v1" => {:atom, :state},
      "atom/status/v1" => {:atom, :status},
      "atom/test/v1" => {:atom, :test},
      "atom/value/v1" => {:atom, :value}
    })
  end
end

Code.ensure_compiled!(JidoActionTest.TestActions.Add)

defmodule JidoActionTest.FlowFixtures.NestedFlow do
  @moduledoc false
  use Jido.Flow, name: "nested_fixture_flow"

  flow do
    step("add",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: 1}
    )

    output(result("add"))
  end
end
