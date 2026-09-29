defmodule Jido.Flow.GraphIdentityTest do
  use ExUnit.Case, async: true
  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction}
  alias JidoActionTest.Fixtures.InlineAuthoring
  alias JidoActionTest.Fixtures.InlineParityFlow

  test "equal inline DSL, and direct graph data has the same semantic identity" do
    dsl = InlineParityFlow.flow()
    direct = InlineAuthoring.direct_flow!()
    assert {:ok, built} = Jido.Flow.new(InlineAuthoring.data())
    assert {:ok, identity} = Flow.semantic_identity(dsl)
    assert %{version: 3, algorithm: :sha256, digest: digest, uuid: uuid} = identity
    assert is_binary(digest)
    assert is_binary(uuid)
    assert Flow.Identity.semantic_digest(dsl) == digest
    assert Flow.semantic_identity(direct) == {:ok, identity}
    assert Flow.semantic_identity(built) == {:ok, identity}
  end

  for field <- [:output, :params] do
    test "identity distinguishes references from literal maps in #{field}" do
      ref = Ref.input([])
      literal = Ref.to_map(ref)

      for {reference, data} <- [
            {ref, literal},
            {%{nested: ref}, %{nested: literal}},
            {Jido.Expr.new!(:eq, [ref, %{value: 42}]),
             Jido.Expr.new!(:eq, [literal, %{value: 42}])}
          ] do
        flows =
          for expression <- [reference, data] do
            params =
              if unquote(field) == :params do
                %{data: expression}
              else
                %{}
              end

            output =
              if unquote(field) == :output do
                %{data: expression}
              else
                Ref.result("echo")
              end

            Flow.new!(
              name: "reference_identity",
              components: [Step.new!(name: "echo", action: EchoParamsAction, params: params)],
              output: output
            )
          end

        [reference_flow, literal_flow] = flows
        refute Flow.semantic_identity(reference_flow) == Flow.semantic_identity(literal_flow)
        assert {:ok, reference_result} = Jido.Exec.run(reference_flow, %{value: 42})
        assert {:ok, literal_result} = Jido.Exec.run(literal_flow, %{value: 42})
        refute reference_result == literal_result

        refute Flow.compile!(reference_flow).compilation_digest ==
                 Flow.compile!(literal_flow).compilation_digest

        for flow <- flows do
          assert {:ok, document, registry} = Flow.Codec.encode(flow)
          assert {:ok, restored} = Flow.Codec.decode(document, registry)
          assert restored == flow
          assert Flow.semantic_identity(restored) == Flow.semantic_identity(flow)
          assert Flow.compile!(flow).semantic_digest == Flow.Identity.semantic_digest(flow)
        end
      end
    end
  end

  test "author order, reference order, and effective order stay separate" do
    first = Step.new!(name: "first", action: Add)

    final =
      Step.new!(
        name: "final",
        action: Add,
        params: %{value: Ref.result("first", :value)},
        needs: ["gate"]
      )

    gate = Step.new!(name: "gate", action: Add)

    flow =
      Flow.new!(
        name: "dependencies",
        components: [first, final, gate],
        output: Ref.result("final")
      )

    assert Enum.map(flow.components, & &1.name) == ["first", "final", "gate"]

    assert {:ok,
            %{"final" => %{needs: ["gate"], references: ["first"], effective: ["first", "gate"]}}} =
             Flow.dependencies(flow)

    assert final.needs == ["gate"]
  end

  test "unknown references and cycles fail without changing author data" do
    assert {:error, %InvalidDefinitionError{}} =
             Flow.new(
               name: "unknown",
               components: [Step.new!(name: "one", action: Add, needs: ["missing"])],
               output: Ref.result("one")
             )

    assert {:error, %InvalidDefinitionError{message: message}} =
             Flow.new(
               name: "cycle",
               components: [
                 Step.new!(name: "one", action: Add, needs: ["two"]),
                 Step.new!(name: "two", action: Add, needs: ["one"])
               ],
               output: Ref.result("one")
             )

    assert message =~ "cycle"
  end

  test "compilation keeps authored metadata in the semantic digest" do
    for meta <- [%{}, %{note: "authored"}] do
      flow =
        Flow.new!(
          name: "metadata_identity",
          components: [
            Step.new!(name: "later", action: Add, needs: ["first"], meta: meta),
            Step.new!(name: "first", action: Add)
          ],
          output: Ref.result("later")
        )

      assert {:ok, identity} = Flow.semantic_identity(flow)
      assert {:ok, compiled} = Flow.compile(flow)
      assert compiled.semantic_digest == identity.digest
      assert {:ok, reordered} = Flow.compile(%{flow | components: Enum.reverse(flow.components)})
      assert reordered.compilation_digest == compiled.compilation_digest
    end
  end

  test "source order does not change semantic identity" do
    one = Step.new!(name: "one", action: Add)
    two = Step.new!(name: "two", action: Add)

    first =
      Flow.new!(
        name: "identity",
        components: [one, two],
        output: %{one: Ref.result("one"), two: Ref.result("two")}
      )

    second =
      Flow.new!(
        name: "identity",
        components: [two, one],
        output: %{one: Ref.result("one"), two: Ref.result("two")}
      )

    refute first == second
    assert Flow.semantic_identity(first) == Flow.semantic_identity(second)
  end
end
