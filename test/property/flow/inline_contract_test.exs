Code.require_file("../support/authoring.exs", __DIR__)
Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.InlineContractTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  @moduletag :property
  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Codec, Ref, Step}
  alias JidoActionTest.Property.Runtime
  alias JidoActionTest.Property.AuthoringFixtures.{Inline, Extended}
  @tag contracts: ["ACT-005", "FLOW-001", "TARGET-001"]
  @tag contract_cases: [
         "ACT-005/lexical-helper",
         "ACT-005/extracted-action",
         "ACT-005/unknown-name"
       ]
  property(
    "an inline body retains lexical helpers and its extracted Action is an executable target"
  ) do
    check(all(value <- integer(-100..100), max_runs: 40)) do
      target = Inline.step_action("work")
      assert {:ok, %Instruction{kind: :action, target: ^target}} = Instruction.resolve(target)
      assert :ok = Instruction.validate(target)

      direct =
        Flow.new!(
          name: "property_inline",
          components: [
            Step.new!(name: "work", action: target, params: %{value: Ref.input(:value)})
          ],
          output: Ref.result("work")
        )

      assert direct == Inline.flow()
      assert {:ok, stored, registry} = Codec.encode(direct)
      assert {:ok, ^direct} = Codec.decode(stored, registry)

      for executable <- [target, Inline, direct] do
        assert Exec.run(executable, %{value: value}) == {:ok, %{value: value * 3 - 7}, [value]}
      end

      assert_raise ArgumentError, fn -> Inline.step_action("missing_#{value}") end
    end
  end

  @tag contracts: ["FLOW-006"]
  @tag contract_cases: ["FLOW-006/extension"]
  property("a host extension expands to canonical declarations with equal execution") do
    check(all(value <- integer(), max_runs: 40)) do
      direct =
        Flow.new!(
          name: "property_extended",
          components: [
            Step.new!(name: "work", action: Runtime.Emit, params: %{value: Ref.input(:value)})
          ],
          output: Ref.result("work")
        )

      data = %{
        output: Ref.result("work"),
        components: [
          %{kind: :step, name: "work", action: Runtime.Emit, params: %{value: Ref.input(:value)}}
        ],
        name: "property_extended"
      }

      assert {:ok, ^direct} = Jido.Flow.new(data)
      assert direct == Extended.flow()

      Runtime.with_context(fn context ->
        assert Exec.run(Extended, %{value: value}, context) == {:ok, %{value: value}, [value]}
        Runtime.assert_calls(context, [value])
      end)
    end
  end
end
