defmodule Jido.Flow.UnknownKeyValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Builder
  alias Jido.Flow.Choice
  alias Jido.Flow.Codec
  alias Jido.Flow.Error.InvalidDefinitionError
  alias Jido.Flow.Iterate
  alias Jido.Flow.Registry
  alias Jido.Flow.Step
  alias JidoActionTest.Fixtures.Actions.Add

  for {module, attrs, label} <- [
        {Flow, %{name: "flow", components: [Step.new!(name: "step", action: Add)], output: %{}},
         "Flow configuration"},
        {Step, %{name: "step", action: Add}, "step configuration"},
        {Jido.Flow.Subflow, %{name: "child", flow: JidoActionTest.Fixtures.NestedFlow},
         "subflow"},
        {Jido.Flow.Map, %{name: "map", collection: [], action: Add}, "map"},
        {Jido.Flow.Reduce, %{name: "reduce", collection: [], initial: %{}, action: Add},
         "reduce"},
        {Jido.Flow.Dispatch, %{name: "dispatch", decision: Add, expander: Add}, "dispatch"},
        {Iterate,
         %{
           name: "iterate",
           action: Add,
           state: %{initial: %{}, update: %{}},
           completion: true,
           max_iterations: 1
         }, "iterate"},
        {Iterate.State, %{schema: [], initial: %{}, update: %{}}, "iterate state"},
        {Choice,
         %{
           name: "choice",
           options: [%{name: "yes", condition: true, action: Add}],
           fallback: %{action: Add}
         }, "choice"},
        {Choice.Option, %{name: "yes", condition: true, action: Add}, "choice option"},
        {Choice.Fallback, %{action: Add}, "choice fallback"}
      ] do
    test "#{inspect(module)} preserves valid input and ordinary unknown-key errors" do
      module = unquote(module)
      attrs = unquote(Macro.escape(attrs))

      assert {:ok, record} = module.new(attrs)
      assert module.new(Map.to_list(attrs)) == {:ok, record}
      assert module.new(record) == {:ok, record}

      assert {:error, error} = module.new(Map.put(attrs, :unexpected, true))
      assert %InvalidDefinitionError{} = error
      assert error.message == "unknown #{unquote(label)} key: :unexpected"

      assert error.details ==
               unquote(Macro.escape(if(module == Flow, do: %{key: :unexpected}, else: %{})))
    end

    for unknown <- [%{nil => :unexpected}, %{nil => :unexpected, unexpected: true}] do
      test "#{inspect(module)} rejects unknown fields #{inspect(unknown)}" do
        module = unquote(module)
        attrs = Map.merge(unquote(Macro.escape(attrs)), unquote(Macro.escape(unknown)))
        message = "unknown #{unquote(label)} key: nil"

        assert {:error, %InvalidDefinitionError{} = error} = module.new(attrs)
        assert error.message == message

        assert error.details ==
                 unquote(Macro.escape(if(module == Flow, do: %{key: nil}, else: %{})))

        assert_raise InvalidDefinitionError, message, fn -> module.new!(attrs) end
      end
    end
  end

  for unknown <- [%{nil => :unexpected}, %{nil => :unexpected, unexpected: true}] do
    test "Builder rejects unknown Flow metadata #{inspect(unknown)}" do
      attrs = Map.merge(%{name: "builder"}, unquote(Macro.escape(unknown)))

      assert {:error,
              %InvalidDefinitionError{
                message: "unknown Flow configuration key: nil",
                details: %{key: nil}
              }} =
               attrs
               |> Builder.new()
               |> Builder.step("step", Add, %{})
               |> Builder.output(%{})
               |> Builder.build()
    end

    test "Builder rejects unknown nested record fields #{inspect(unknown)}" do
      unknown = unquote(Macro.escape(unknown))
      option = %{name: "yes", condition: true, action: Add}
      fallback = %{action: Add}
      state = %{initial: %{}, update: %{}}
      builder = Builder.new(name: "nested") |> Builder.output(%{})

      for {invalid_builder, message, details} <- [
            {Builder.choice(builder, "choice", [Map.merge(option, unknown)], fallback),
             "unknown choice option key: nil", %{path: [:options, 0]}},
            {Builder.choice(builder, "choice", [option], Map.merge(fallback, unknown)),
             "unknown choice fallback key: nil", %{}},
            {Builder.iterate(builder, "iterate", Add, %{}, Map.merge(state, unknown),
               completion: true,
               max_iterations: 1
             ), "unknown iterate state key: nil", %{}}
          ] do
        assert {:error, %InvalidDefinitionError{} = error} = Builder.build(invalid_builder)
        assert error.message == message
        assert error.details == details
      end
    end

    test "Codec rejects unknown root and component fields #{inspect(unknown)}" do
      flow =
        Flow.new!(name: "stored", components: [Step.new!(name: "step", action: Add)], output: %{})

      registry = Registry.new!(%{"add" => {:action, Add}, "none" => {:schema, []}})
      assert {:ok, document} = Codec.encode(flow, registry)
      assert {:ok, ^flow} = Codec.decode(document, registry)
      unknown = unquote(Macro.escape(unknown))

      for {invalid, path} <- [
            {Map.merge(document, unknown), ["nil"]},
            {update_in(document, ["components", Access.at(0)], &Map.merge(&1, unknown)),
             ["components", 0, "nil"]}
          ] do
        assert {:error,
                %InvalidDefinitionError{
                  message: "stored Flow contains an unknown field",
                  details: %{field: nil, path: ^path}
                }} = Codec.decode(invalid, registry)
      end
    end
  end
end

defmodule Jido.Flow.UnknownKeyDSLValidationTest do
  use ExUnit.Case, async: false

  for {suffix, unknown} <- [
        {"Nil", %{nil => :unexpected}},
        {"NilAndUnknown", %{nil => :unexpected, unexpected: true}}
      ] do
    test "DSL rejects unknown Flow configuration #{inspect(unknown)}" do
      module = Module.concat(__MODULE__, unquote(suffix))
      attrs = Map.merge(%{name: "invalid_config"}, unquote(Macro.escape(unknown)))

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

      source = """
      defmodule #{inspect(module)} do
        use Jido.Flow, #{inspect(attrs)}
        flow do
          step "step", action: JidoActionTest.Fixtures.Actions.Add, params: %{}
          output %{}
        end
      end
      """

      error =
        assert_raise CompileError, fn -> Code.compile_string(source, "unknown_flow_key.ex") end

      assert error.file == "unknown_flow_key.ex"
      assert error.line == 2
      assert error.description =~ "unknown Flow configuration key: nil"
    end
  end
end
