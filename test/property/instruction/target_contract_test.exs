Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Instruction.TargetContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :property
  alias Jido.{Executable, Flow}
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Property.Runtime

  defmodule Child do
    use Jido.Flow, name: "property_target"

    flow do
      step "work", action: JidoActionTest.Property.Runtime.Emit, params: %{value: input(:value)}
      output result("work")
    end
  end

  defmodule Mismatch do
    def __jido_executable__, do: Executable.action(Runtime.Emit)
  end

  @tag contracts: ["TARGET-001", "FLOW-004"]
  @tag contract_cases: [
         "TARGET-001/action",
         "TARGET-001/flow-module",
         "TARGET-001/flow-value",
         "TARGET-001/descriptor-owner",
         "TARGET-001/unsupported-shapes"
       ]
  property "resolution preserves exact target kind and contains unsupported targets without work" do
    check all(value <- integer(), max_runs: 40) do
      flow =
        Flow.new!(
          name: "target",
          components: [Step.new!(name: "work", action: Runtime.Emit, params: %{value: value})],
          output: Ref.result("work")
        )

      for {target, kind} <- [{Runtime.Emit, :action}, {Child, :flow}, {flow, :flow}] do
        assert {:ok, %Executable{kind: ^kind, target: ^target}} = Executable.resolve(target)
        assert :ok = Executable.validate(target)
      end

      for invalid <- [value, Integer.to_string(value), %{}, fn -> value end, Mismatch, String] do
        assert {:error, %Jido.Action.Error.ConfigurationError{}} = Executable.resolve(invalid)
      end
    end
  end
end
