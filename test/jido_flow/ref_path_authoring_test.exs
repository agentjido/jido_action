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
  alias Jido.Flow.{Builder, Codec, Iterate, Reduce, Ref, Step}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Error.InvalidDefinitionError
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  defmodule CountedAction do
    use Jido.Action, name: "counted_reference_action"

    def run(params, %{calls: calls}) do
      Agent.update(calls, &(&1 + 1))
      {:ok, params}
    end
  end

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

      assert {:error,
              %Jido.Flow.Error.ExecutionFailureError{
                details: %{reason: :missing_index, path: [:payload, "items", 0]}
              }} = Jido.Exec.run(flow, %{payload: %{"items" => []}}, %{optional: nil})
    end
  end

  test "atom paths prefer present atom keys, including nil and false, before string keys" do
    flow =
      Flow.new!(
        name: "key_precedence",
        components: [
          Step.new!(name: "echo", action: EchoParamsAction, params: %{value: Ref.input(:value)})
        ],
        output: Ref.result("echo")
      )

    for value <- [nil, false, 7] do
      assert Jido.Exec.run(flow, %{:value => value, "value" => 42}) == {:ok, %{value: value}}
    end

    assert Jido.Exec.run(flow, %{"value" => 42}) == {:ok, %{value: 42}}
    assert {:error, %{details: %{reason: :missing_key}}} = Jido.Exec.run(flow, %{})
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

  test "Builder.select rejects an invalid source with a structured error" do
    for path <- [[:payload | :tail], [:payload, :value | nil], [nil], nil, :payload, 0, %{}] do
      source = %Ref{source: :input, path: path}

      error =
        assert_raise InvalidDefinitionError, "invalid flow ref", fn ->
          Builder.select(source, :value)
        end

      assert error.details.reason == :path
      assert error.details.ref == source
    end
  end

  test "Builder.select preserves valid global and local reference sources" do
    for source <- [
          Ref.input([]),
          Ref.context(),
          Ref.result("echo"),
          Ref.item(),
          Ref.accumulator(),
          Ref.state(),
          Ref.body_result()
        ] do
      assert Builder.select(source, [:payload, "items", 0]) ==
               %{source | path: [:payload, "items", 0]}

      assert Builder.select(source, nil) == source
    end

    for source <- [Ref.item_index(), Ref.item_id(), Ref.iteration_index()] do
      assert Builder.select(source, []) == source
    end
  end

  test "Exec rejects invalid paths for every source before any Action work" do
    calls = start_supervised!({Agent, fn -> 0 end})
    first = Step.new!(name: "first", action: CountedAction)

    components =
      for ref <- [Ref.input([]), Ref.context(), Ref.result("first")] do
        Step.new!(name: "node", action: EchoParamsAction, params: %{value: ref})
      end

    components =
      components ++
        for ref <- [Ref.item(), Ref.item_index(), Ref.item_id()] do
          FlowMap.new!(
            name: "node",
            action: EchoParamsAction,
            collection: [],
            params: %{value: ref}
          )
        end

    components =
      components ++
        [
          Reduce.new!(
            name: "node",
            action: EchoParamsAction,
            collection: [],
            initial: %{},
            params: %{value: Ref.accumulator()}
          )
        ] ++
        for ref <- [Ref.state(), Ref.iteration_index()] do
          Iterate.new!(
            name: "node",
            action: EchoParamsAction,
            params: %{value: ref},
            state: [schema: [], initial: %{}, update: %{}],
            completion: true,
            max_iterations: 1
          )
        end

    for path <- [[nil], [:value, nil, 0], [:value, nil], [:value | :tail], [-1], [0.0]],
        component <- components do
      invalid = put_in(component.params.value.path, path)

      flow = %Flow{
        name: "invalid_paths",
        components: [first, invalid],
        output: Ref.result("node")
      }

      assert {:error, %InvalidDefinitionError{}} = Jido.Exec.run(flow, %{}, %{calls: calls})
      assert {:error, %InvalidDefinitionError{}} = Jido.Exec.start(flow, %{}, %{calls: calls})
    end

    iterate =
      Iterate.new!(
        name: "node",
        action: EchoParamsAction,
        state: [schema: [], initial: %{}, update: %{value: Ref.body_result()}],
        completion: true,
        max_iterations: 1
      )

    invalid = put_in(iterate.state.update.value.path, [nil])
    flow = %Flow{name: "invalid_update", components: [first, invalid], output: Ref.result("node")}

    assert {:error, %InvalidDefinitionError{}} = Jido.Exec.run(flow, %{}, %{calls: calls})
    assert {:error, %InvalidDefinitionError{}} = Jido.Exec.start(flow, %{}, %{calls: calls})
    assert Agent.get(calls, & &1) == 0

    assert {:ok, %{}} = Jido.Exec.run(CountedAction, %{}, %{calls: calls})
    assert Agent.get(calls, & &1) == 1
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
