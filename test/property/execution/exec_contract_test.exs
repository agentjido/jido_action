defmodule JidoActionTest.Property.Execution.ExecContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.Add

  property "an Action and an equivalent one-step Flow have the same result" do
    check all(value <- integer(-10_000..10_000), amount <- integer(-100..100)) do
      flow =
        JidoActionTest.FlowBuilder.new!(
          name: "one_step_property",
          components: [
            JidoActionTest.FlowComponent.step!(
              name: "add",
              action: Add,
              params: %{value: Ref.input(:value), amount: Ref.input(:amount)}
            )
          ],
          output: Ref.result("add")
        )

      input = %{value: value, amount: amount}
      assert Exec.run(Add, input) == Exec.run(flow, input)
    end
  end
end
