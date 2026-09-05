defmodule Jido.Flow.RefPathAuthoringTest.ValidFlow do
  @moduledoc false

  use Jido.Flow, name: "reference_paths"

  flow do
    step "echo",
      action: JidoActionTest.Fixtures.Actions.EchoParamsAction,
      params: %{
        input: input([]),
        selected: input([:payload, "items", 0]),
        context: context(:optional),
        literal: nil
      }

    output(%{echo: result("echo"), selected: select(result("echo"), :selected)})
  end
end

defmodule Jido.Flow.RefPathAuthoringTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Builder, Codec, Ref, Step}
  alias Jido.Flow.Error.InvalidDefinitionError
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  test "all authoring forms preserve supported paths and present nil values" do
    params = %{
      input: Ref.input([]),
      selected: Ref.input([:payload, "items", 0]),
      context: Ref.context(:optional),
      literal: nil
    }

    output = %{echo: Ref.result("echo"), selected: Ref.result("echo", :selected)}

    direct =
      Flow.new!(
        name: "reference_paths",
        components: [Step.new!(name: "echo", action: EchoParamsAction, params: params)],
        output: output
      )

    assert {:ok, built} =
             Builder.new(name: "reference_paths")
             |> Builder.step("echo", EchoParamsAction, params)
             |> Builder.output(output)
             |> Builder.build()

    assert {:ok, document, registry} = Codec.encode(direct)

    assert {:ok, decoded} =
             document |> Jason.encode!() |> Jason.decode!() |> Codec.decode(registry)

    input = %{payload: %{"items" => [nil]}}
    expected = %{echo: %{input: input, selected: nil, context: nil, literal: nil}, selected: nil}

    for flow <- [direct, built, decoded, __MODULE__.ValidFlow.flow()] do
      assert flow == direct
      assert Jido.Exec.run(flow, input, %{optional: nil}) == {:ok, expected}
    end
  end

  test "Flow, Builder, and Codec reject malformed reference paths" do
    step = Step.new!(name: "echo", action: EchoParamsAction)
    valid = Flow.new!(name: "invalid_paths", components: [step], output: Ref.input([]))
    assert {:ok, document, registry} = Codec.encode(valid)

    for path <- [[nil], ["value", nil, 0], ["value", nil], ["value" | :tail], [-1], [1.5]] do
      ref = Ref.input(path)

      assert {:error, %InvalidDefinitionError{}} =
               Flow.new(name: "invalid_paths", components: [step], output: %{nested: [ref]})

      assert {:error, %InvalidDefinitionError{}} =
               Builder.new(name: "invalid_paths")
               |> Builder.step("echo", EchoParamsAction, %{nested: [Builder.input(path)]})
               |> Builder.output(Builder.result("echo"))
               |> Builder.build()

      assert {:error, %InvalidDefinitionError{}} =
               Builder.new(name: "invalid_paths")
               |> Builder.step("echo", EchoParamsAction, %{})
               |> Builder.output(%{nested: [Builder.select(Builder.input([]), path)]})
               |> Builder.build()

      invalid_flow = %{valid | output: ref}
      assert {:error, %InvalidDefinitionError{}} = Codec.encode(invalid_flow, registry)

      stored_ref = %{"$ref" => %{"source" => "input", "component" => nil, "path" => path}}

      assert {:error, %InvalidDefinitionError{}} =
               Codec.decode(%{document | "output" => stored_ref}, registry)
    end
  end

  test "the module DSL rejects nil segments and malformed paths before execution" do
    for {path, index} <-
          Enum.with_index([
            "[nil]",
            "[nil, :value]",
            "[:value, nil, 0]",
            "[:value, nil]",
            "[:value | :tail]",
            "[-1]",
            "[%{}]"
          ]) do
      code = """
      defmodule #{__MODULE__}.Invalid#{index} do
        use Jido.Flow, name: "invalid_reference_path"

        flow do
          step "echo",
            action: JidoActionTest.Fixtures.Actions.EchoParamsAction,
            params: %{nested: [input(#{path})]}

          output(result("echo"))
        end
      end
      """

      assert_raise CompileError, ~r/invalid reference path|unsupported Flow expression/, fn ->
        Code.compile_string(code)
      end
    end
  end
end
