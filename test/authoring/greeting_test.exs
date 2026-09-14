Code.require_file("support/greeting.ex", __DIR__)

defmodule JidoActionTest.Authoring.GreetingTest do
  use ExUnit.Case, async: false
  @moduletag :authoring

  alias Jido.Flow, as: FlowDefinition
  alias Jido.Flow.{Builder, Codec, Ref, Step}
  alias JidoActionTest.Authoring.Greeting.{Flow, Greet, Normalize}

  test "an authored Action validates input and carries caller context" do
    assert {:ok, %{name: "Ada"}} = Jido.Exec.run(Normalize, %{name: " Ada "})

    assert {:ok, %{message: "Hi, Ada!"}} =
             Jido.Exec.run(Greet, %{name: "Ada"}, %{prefix: "Hi"})

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.Exec.run(Normalize, %{name: 12})
  end

  test "module DSL, Builder, and constructors author the same executable Flow" do
    module_flow = Flow.flow()

    builder =
      Builder.new(
        name: Flow.name(),
        schema: Flow.schema(),
        output_schema: Flow.output_schema()
      )
      |> Builder.step("normalize", Normalize, %{name: Builder.input(:name)})
      |> Builder.step("greet", Greet, %{name: Builder.result("normalize", :name)})
      |> Builder.output(Builder.result("greet"))

    assert {:ok, builder_flow} = Builder.build(builder)

    direct_flow =
      FlowDefinition.new!(
        name: Flow.name(),
        schema: Flow.schema(),
        output_schema: Flow.output_schema(),
        components: [
          Step.new!(name: "normalize", action: Normalize, params: %{name: Ref.input(:name)}),
          Step.new!(
            name: "greet",
            action: Greet,
            params: %{name: Ref.result("normalize", :name)}
          )
        ],
        output: Ref.result("greet")
      )

    assert module_flow == builder_flow
    assert module_flow == direct_flow

    for authored <- [Flow, module_flow, builder_flow, direct_flow] do
      assert {:ok, %{message: "Hi, Ada!"}} =
               Jido.Exec.run(authored, %{name: " Ada "}, %{prefix: "Hi"})
    end
  end

  test "stored JSON restores the authored Flow through a trusted registry" do
    flow = Flow.flow()
    assert {:ok, document, registry} = Codec.encode(flow)
    assert {:ok, restored} = Codec.decode(document |> JSON.encode!() |> JSON.decode!(), registry)
    assert restored == flow

    assert {:ok, %{message: "Hello, Ada!"}} =
             Jido.Exec.run(restored, %{name: " Ada "}, %{prefix: "Hello"})
  end

  test "a source Flow without an output fails at authoring time" do
    assert_raise CompileError, ~r/Flow output is required/, fn ->
      Code.compile_file(Path.join(__DIR__, "support/missing_output.ex"))
    end
  end
end
