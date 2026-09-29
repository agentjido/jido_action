Code.require_file("../support/fuzz.exs", __DIR__)
Code.require_file("../support/runtime.exs", __DIR__)

defmodule JidoActionTest.Property.Flow.ValidationContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias JidoActionTest.Property.Fuzz
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Codec, Ref, Step}
  alias JidoActionTest.Property.Runtime
  @tag contracts: ["FLOW-003", "FLOW-004"]
  @tag contract_cases: [
         "FLOW-003/duplicate",
         "FLOW-003/unknown",
         "FLOW-003/nil-output",
         "FLOW-004/invalid-graph"
       ]
  property("duplicate names unknown edges cycles and nil output fail without work") do
    check(all(value <- integer(), max_runs: 30)) do
      components =
        for name <- ["a", "b"] do
          Step.new!(name: name, action: Runtime.Emit, params: %{value: value})
        end

      flow = Flow.new!(name: "invalid_graph", components: components, output: Ref.result("b"))
      assert {:ok, document, registry} = Codec.encode(flow)

      for fault <- [:duplicate, :unknown, :cycle, :output] do
        {invalid, stored} = fault(flow, document, fault)

        data = %{
          output: invalid.output,
          components:
            Enum.map(
              invalid.components,
              fn step ->
                %{
                  kind: :step,
                  name: step.name,
                  action: step.action,
                  params: step.params,
                  needs: step.needs
                }
              end
            ),
          name: flow.name
        }

        assert {:error, direct_error} = Flow.new(Map.from_struct(invalid))
        assert {:error, data_error} = Jido.Flow.new(data)
        assert {:error, codec_error} = Codec.decode(JSON.decode!(JSON.encode!(stored)), registry)
        assert is_exception(direct_error)
        assert data_error.message == direct_error.message
        assert is_exception(codec_error)

        Runtime.with_context(fn context ->
          assert {:error, _} = Flow.validate(invalid)
          assert {:error, _} = Flow.validate_executable(invalid)
          assert {:error, _} = Exec.run(invalid, %{}, context, Runtime.options(context))
          Runtime.assert_calls(context, [])
        end)
      end
    end
  end

  @tag contracts: ["FLOW-004"]
  @tag contract_cases: [
         "FLOW-004/validate",
         "FLOW-004/validate-executable",
         "FLOW-004/inspection",
         "FLOW-004/invalid-target"
       ]
  property("validation inspection and Codec preserve inertness including invalid targets") do
    check(all(value <- integer(), max_runs: 30)) do
      Runtime.with_context(fn context ->
        flow =
          Flow.new!(
            name: "inert",
            components: [Step.new!(name: "work", action: Runtime.Emit, params: %{value: value})],
            output: Ref.result("work")
          )

        assert {:ok, ^flow} = Flow.validate(flow)
        assert {:ok, ^flow} = Flow.validate_executable(flow)
        assert {:ok, _} = Flow.dependencies(flow)
        assert {:ok, _} = Flow.explain(flow)
        assert {:ok, _} = Flow.semantic_identity(flow)
        assert {:ok, _} = Flow.compile(flow)
        assert {:ok, document, registry} = Codec.encode(flow)
        assert {:ok, ^flow} = Codec.decode(document, registry)
        assert {:ok, ^flow} = Codec.diagnose(document, registry)
        invalid = %{flow | components: [%{hd(flow.components) | action: String}]}
        assert {:ok, ^invalid} = Flow.validate(invalid)
        assert {:error, _} = Flow.validate_executable(invalid)
        Runtime.assert_calls(context, [])
      end)
    end
  end

  @tag contracts: ["FLOW-005", "STORE-001"]
  @tag contract_cases: [
         "FLOW-005/reference-vs-data",
         "FLOW-005/codec-identity",
         "FLOW-005/compiled-digest"
       ]
  property(
    "semantic identity preserves round trips and distinguishes reference data from literal maps"
  ) do
    check(all(value <- integer(), max_runs: 40)) do
      reference = Ref.input(:value)

      flows =
        for expression <- [reference, Ref.to_map(reference)] do
          Flow.new!(
            name: "identity",
            components: [Step.new!(name: "work", action: Runtime.Emit, params: %{value: value})],
            output: %{value: expression}
          )
        end

      [reference_flow, literal_flow] = flows
      refute Flow.semantic_identity(reference_flow) == Flow.semantic_identity(literal_flow)

      for flow <- flows do
        assert {:ok, identity} = Flow.semantic_identity(flow)
        assert identity.algorithm == :sha256
        assert byte_size(identity.digest) == 64
        assert {:ok, compiled} = Flow.compile(flow)
        assert compiled.semantic_digest == identity.digest
        assert {:ok, document, registry} = Codec.encode(flow)
        assert {:ok, restored} = Codec.decode(document, registry)
        assert Flow.semantic_identity(restored) == {:ok, identity}
      end
    end
  end

  @tag :fuzz
  @tag max_runs: 300, max_run_time: 300_000, timeout: 900_000, max_nodes: 12
  @tag contracts: ["FLOW-003", "FLOW-004"]
  @tag contract_cases: [
         "FLOW-003/fuzz-duplicate",
         "FLOW-003/fuzz-cycle",
         "FLOW-003/fuzz-unknown",
         "FLOW-003/fuzz-output",
         "FLOW-004/fuzz-inert-inspection"
       ]
  test("fuzz: generated graph defects reject through every public data form", context) do
    generator =
      list_of(tuple({integer(), integer(0..100)}), min_length: 2, max_length: context.max_nodes)
      |> map(fn nodes -> Enum.map(nodes, &Tuple.to_list/1) end)

    Fuzz.check("graph_rejections", generator, Map.to_list(context), fn nodes ->
      names = [
        "a",
        "b"
        | for i <- 2..length(nodes), i < length(nodes) do
            "n#{i}"
          end
      ]

      components =
        nodes
        |> Enum.with_index()
        |> Enum.map(fn {[value, parent], index} ->
          needs =
            if index == 0 or rem(parent, index + 1) == 0 do
              []
            else
              [Enum.at(names, rem(parent, index))]
            end

          Step.new!(
            name: Enum.at(names, index),
            action: Runtime.Emit,
            params: %{value: value},
            needs: needs
          )
        end)

      flow =
        Flow.new!(
          name: "rejected_graph",
          components: components,
          output: Ref.result(List.last(names))
        )

      assert {:ok, document, registry} = Codec.encode(flow)

      for defect <- [:duplicate, :unknown, :cycle, :output] do
        {invalid, stored} = fault(flow, document, defect)

        data = %{
          output: invalid.output,
          components:
            Enum.map(
              invalid.components,
              fn step ->
                %{
                  kind: :step,
                  name: step.name,
                  action: step.action,
                  params: step.params,
                  needs: step.needs
                }
              end
            ),
          name: flow.name
        }

        assert {:error, direct_error} = Flow.new(Map.from_struct(invalid))
        assert {:error, data_error} = Jido.Flow.new(data)
        assert data_error.message == direct_error.message
        assert {:error, error} = Codec.decode(JSON.decode!(JSON.encode!(stored)), registry)
        assert is_exception(error)

        Runtime.with_context(fn runtime ->
          assert {:error, _} = Flow.validate(invalid)
          assert {:error, _} = Flow.validate_executable(invalid)
          assert {:error, _} = Exec.run(invalid, %{}, runtime, Runtime.options(runtime))
          Runtime.assert_calls(runtime, [])
        end)
      end

      Runtime.with_context(fn runtime ->
        assert {:ok, ^flow} = Flow.validate(flow)
        assert {:ok, ^flow} = Flow.validate_executable(flow)

        for operation <- [:dependencies, :explain, :semantic_identity, :compile] do
          assert {:ok, _} = apply(Flow, operation, [flow])
        end

        invalid = %{flow | components: List.update_at(components, 0, &%{&1 | action: String})}
        assert {:error, _} = Flow.validate_executable(invalid)
        assert {:error, _} = Exec.run(invalid, %{}, runtime, Runtime.options(runtime))
        Runtime.assert_calls(runtime, [])
      end)

      ["nodes:#{length(nodes)}", "all-defects", "inert-inspection"]
    end)
  end

  defp fault(flow, document, :duplicate) do
    {%{flow | components: List.update_at(flow.components, 1, &%{&1 | name: "a"})},
     put_in(document, ["components", Access.at(1), "name"], "a")}
  end

  defp fault(flow, document, :unknown) do
    {%{flow | components: List.update_at(flow.components, 1, &%{&1 | needs: ["absent"]})},
     put_in(document, ["components", Access.at(1), "needs"], ["absent"])}
  end

  defp fault(flow, document, :cycle) do
    components =
      flow.components
      |> List.update_at(0, &%{&1 | needs: ["b"]})
      |> List.update_at(1, &%{&1 | needs: ["a"]})

    document =
      document
      |> put_in(["components", Access.at(0), "needs"], ["b"])
      |> put_in(["components", Access.at(1), "needs"], ["a"])

    {%{flow | components: components}, document}
  end

  defp fault(flow, document, :output) do
    {%{flow | output: nil}, Map.put(document, "output", nil)}
  end
end
