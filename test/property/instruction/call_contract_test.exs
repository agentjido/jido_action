Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Instruction.CallContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias JidoActionTest.Property.Fuzz
  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Ref, Step}

  defmodule Echo do
    use Jido.Action, name: "property_instruction_echo"
    @impl true
    def run(params, context),
      do: {:ok, %{params: params, context: Map.drop(context, [:__jido_exec__])}}
  end

  defmodule Child do
    use Jido.Flow, name: "fuzz_instruction_child"

    flow do
      step "echo",
        action: JidoActionTest.Property.Instruction.CallContractTest.Echo,
        params: input()

      output result("echo")
    end
  end

  defmodule WrongOwner do
  end

  @tag :fuzz
  @tag max_runs: 500, max_run_time: 300_000, timeout: 900_000
  @tag contracts: ["INS-001", "TARGET-001"]
  @tag contract_cases: [
         "INS-001/fuzz-shallow-overrides",
         "INS-001/fuzz-metadata",
         "TARGET-001/fuzz-all-targets",
         "TARGET-001/fuzz-descriptors"
       ]
  test "fuzz: call data uses shallow overrides and keeps exact Instruction targets", context do
    value = one_of([integer(), boolean(), constant(nil), list_of(integer(), max_length: 10)])
    data = optional_map(Map.new(~w(a b c nested), &{&1, value}))

    generator =
      fixed_map(%{
        "stored" => data,
        "incoming" => data,
        "label" => string(:alphanumeric, max_length: 40)
      })

    Fuzz.check("instruction_targets", generator, Map.to_list(context), fn sample ->
      params = Map.put(sample["stored"], "nested", %{"old" => sample["stored"]})
      incoming = Map.put(sample["incoming"], "nested", %{"new" => sample["incoming"]})

      expected =
        for key <- Enum.uniq(Map.keys(params) ++ Map.keys(incoming)), into: %{} do
          {key, if(Map.has_key?(incoming, key), do: incoming[key], else: params[key])}
        end

      metadata = %{timeout: 0, max_concurrency: -1, label: sample["label"]}

      for {target, kind} <- [{Echo, :action}, {Child, :flow}, {Child.flow(), :flow}],
          form <- [:map, :keyword] do
        assert {:ok, %Instruction{kind: ^kind, target: ^target}} =
                 Instruction.resolve(target)

        attrs = %{target: target, params: params, context: params, metadata: metadata}

        assert {:ok, instruction} =
                 Instruction.new(if(form == :map, do: attrs, else: Map.to_list(attrs)))

        normalized = Instruction.normalize!(instruction, incoming, incoming)
        assert normalized.target == target
        assert normalized.params == expected
        assert normalized.context == expected
        assert normalized.metadata == metadata

        assert Exec.run(instruction, incoming, incoming) ==
                 {:ok, %{params: expected, context: expected}}
      end

      for invalid <- [WrongOwner, String, sample["label"], sample["stored"], fn -> :invalid end] do
        assert {:error, %Jido.Action.Error.ConfigurationError{}} =
                 Instruction.resolve(invalid)
      end

      for field <- [:params, :context, :metadata] do
        assert {:error, error} = Instruction.new(Map.put(%{target: Echo}, field, false))
        assert is_exception(error)
      end

      ["action", "flow-module", "flow-value", "shallow-merge", "inert-metadata"]
    end)
  end

  @tag contracts: ["INS-001"]
  @tag contract_cases: [
         "INS-001/action-target",
         "INS-001/flow-value",
         "INS-001/map-constructor",
         "INS-001/keyword-constructor",
         "INS-001/shallow-params",
         "INS-001/shallow-context",
         "INS-001/metadata"
       ]
  property "construction and execution preserve shallow overrides for Action and Flow targets" do
    check all(
            stored <- integer(),
            incoming <- integer(),
            label <- string(:alphanumeric, max_length: 12),
            max_runs: 40
          ) do
      flow =
        Flow.new!(
          name: "instruction",
          components: [Step.new!(name: "echo", action: Echo, params: Ref.input([]))],
          output: Ref.result("echo")
        )

      for target <- [Echo, flow], form <- [:map, :keyword] do
        params = %{value: stored, nested: %{old: stored}, kept: false}
        context = %{label: "stored", nested: %{old: stored}, kept: false}
        metadata = %{label: label, max_concurrency: -1, timeout: 0}
        attrs = %{target: target, params: params, context: context, metadata: metadata}
        attrs = if form == :keyword, do: Map.to_list(attrs), else: attrs
        assert {:ok, instruction} = Instruction.new(attrs)
        extra_params = %{value: incoming, nested: %{new: incoming}}
        extra_context = %{label: label, nested: %{new: incoming}}
        normalized = Instruction.normalize!(instruction, extra_params, extra_context)
        assert normalized.metadata == metadata
        assert normalized.params == %{value: incoming, nested: %{new: incoming}, kept: false}
        assert normalized.context == %{label: label, nested: %{new: incoming}, kept: false}

        assert Exec.run(instruction, extra_params, extra_context) ==
                 {:ok, %{params: normalized.params, context: normalized.context}}
      end
    end
  end

  @tag contracts: ["INS-001"]
  @tag contract_cases: ["INS-001/nil-maps", "INS-001/invalid-maps", "INS-001/removed-fields"]
  property "nil maps normalize to empty and invalid invocation data remains rejected" do
    check all(value <- integer(), max_runs: 30) do
      assert {:ok, instruction} =
               Instruction.new(target: Echo, params: nil, context: nil, metadata: nil)

      assert instruction.params == %{}
      assert instruction.context == %{}
      assert instruction.metadata == %{}

      for field <- [:params, :context, :metadata], invalid <- [false, value, {value}] do
        assert {:error, error} = Instruction.new(Map.put(%{target: Echo}, field, invalid))
        assert is_exception(error)
      end

      for field <- [:id, :action, :flow, :opts] do
        assert {:error, _} = Instruction.new(Map.put(%{target: Echo}, field, value))
      end
    end
  end
end
