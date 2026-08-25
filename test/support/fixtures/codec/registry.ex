defmodule JidoActionTest.Fixtures.CodecRegistry do
  @moduledoc false

  alias Jido.Flow.Registry
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  def mixed do
    Registry.new!(%{
      "actions/add" => {:action, Add},
      "actions/multiply" => {:action, Multiply},
      "flows/nested" => {:flow, NestedFlow},
      "schemas/empty" => {:schema, []},
      "atoms/add" => {:atom, :add},
      "atoms/amount" => {:atom, :amount},
      "atoms/count" => {:atom, :count},
      "atoms/debug" => {:atom, :debug},
      "atoms/go" => {:atom, :go},
      "atoms/items" => {:atom, :items},
      "atoms/kind" => {:atom, :kind},
      "atoms/owner" => {:atom, :owner},
      "atoms/value" => {:atom, :value}
    })
  end

  def storage do
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
