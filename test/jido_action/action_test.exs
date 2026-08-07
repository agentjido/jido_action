defmodule Jido.ActionTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action
  alias Jido.Action.Output
  alias JidoTest.TestActions.FullAction
  alias JidoTest.TestActions.NoOutputSchemaAction
  alias JidoTest.TestActions.NoSchema
  alias JidoTest.TestActions.OutputSchemaAction

  describe "action creation and metadata" do
    test "creates a valid action with retained metadata" do
      assert FullAction.name() == "full_action"
      assert FullAction.description() == "A full action for testing"
      assert %Zoi.Types.Map{fields: fields} = FullAction.schema()
      assert fields |> field_keys() |> Enum.sort() == [:a, :b]
    end

    test "creates a valid action with no schema" do
      assert NoSchema.name() == "add_two"
      assert NoSchema.description() == "Adds 2 to the input value"
      assert NoSchema.schema() == []
    end

    test "runtime compiled action exposes metadata and default run error" do
      module = unique_module("RuntimeDefaultAction")

      create_module(
        module,
        quote do
          use Jido.Action,
            name: "runtime_default_action",
            description: "Runtime default action"
        end
      )

      assert module.name() == "runtime_default_action"
      assert module.description() == "Runtime default action"
      assert module.schema() == []
      assert module.output_schema() == []

      assert {:error, %Jido.Action.Error.ConfigurationError{message: message}} =
               module.run(%{}, %{})

      assert message =~ "run/2 must be implemented"
    end

    test "runtime compiled action supports non-literal options" do
      module = unique_module("RuntimeDynamicOptionsAction")
      schema = Zoi.object(%{value: Zoi.integer()})
      output_schema = Zoi.object(%{doubled: Zoi.integer()})

      create_module(
        module,
        quote do
          opts = [
            name: "runtime_dynamic_options_action",
            schema: unquote(Macro.escape(schema)),
            output_schema: unquote(Macro.escape(output_schema))
          ]

          use Jido.Action, opts

          @impl true
          def run(%{value: value}, _context), do: {:ok, %{doubled: value * 2}}
        end
      )

      assert module.name() == "runtime_dynamic_options_action"

      assert {:ok, %{value: 3, extra: "kept"}} =
               module.validate_params(%{value: 3, extra: "kept"})

      assert {:ok, %{doubled: 6, extra: "kept"}} =
               module.validate_output(%{doubled: 6, extra: "kept"})

      assert {:ok, %{doubled: 6}} = module.run(%{value: 3}, %{})
    end

    test "runtime compiled action supports nested schema variables" do
      module = unique_module("RuntimeSchemaVariableAction")

      create_module(
        module,
        quote do
          input_type = Zoi.integer()
          output_type = Zoi.string()

          use Jido.Action,
            name: "runtime_schema_variable_action",
            schema: Zoi.object(%{value: input_type}),
            output_schema: Zoi.object(%{result: output_type})
        end
      )

      assert {:ok, %{value: 3}} = module.validate_params(%{value: 3})
      assert {:ok, %{result: "ok"}} = module.validate_output(%{result: "ok"})
    end

    test "reports closure schemas that cannot be stored from dynamic options" do
      module = unique_module("RuntimeDynamicClosureSchemaAction")

      assert_raise CompileError,
                   ~r/declare the closure-based :schema option inline/,
                   fn ->
                     create_module(
                       module,
                       quote do
                         opts = [
                           name: "runtime_dynamic_closure_schema_action",
                           schema:
                             Zoi.object(%{
                               value:
                                 Zoi.integer()
                                 |> Zoi.refine(fn value -> value > 0 end)
                             })
                         ]

                         use Jido.Action, opts
                       end
                     )
                   end
    end

    test "evaluates non-literal options once" do
      module = unique_module("CountedDynamicOptionsAction")
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      create_module(
        module,
        quote do
          use Jido.Action, Jido.ActionTest.counted_options(unquote(counter))
        end
      )

      assert Agent.get(counter, & &1) == 1
      assert module.name() == "counted_dynamic_options_action"
    end

    test "invalid action configuration raises at compile time" do
      module = unique_module("InvalidActionConfig")

      assert_raise CompileError, ~r/Action configuration validation failed/, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Jido.Action,
            name: "   "
        end
        """)
      end
    end

    test "unknown action options raise at compile time" do
      module = unique_module("UnknownActionOption")

      assert_raise CompileError, ~r/unrecognized key: output_shema/, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use Jido.Action,
            name: "unknown_action_option",
            output_shema: Zoi.object(%{value: Zoi.integer()})
        end
        """)
      end
    end
  end

  describe "configuration schema validation" do
    test "validates non-blank string action names" do
      assert :ok = Action.validate_name("valid_name")
      assert :ok = Action.validate_name("ValidName")
      assert :ok = Action.validate_name("a")
      assert :ok = Action.validate_name("A")
    end

    test "validates action names with external or display-oriented punctuation" do
      assert :ok = Action.validate_name("valid_name_123")
      assert :ok = Action.validate_name("TestAction42")
      assert :ok = Action.validate_name("billing.charge-card")
      assert :ok = Action.validate_name("Send Email")
      assert :ok = Action.validate_name("checkout/v2")
    end

    test "rejects invalid action names" do
      assert {:error, "Action name cannot be blank."} = Action.validate_name("")
      assert {:error, "Action name cannot be blank."} = Action.validate_name(" \t\n")

      assert {:error, "Action name cannot exceed 256 bytes."} =
               Action.validate_name(String.duplicate("a", 257))

      assert {:error, "Action name must be a string."} = Action.validate_name(nil)
      assert {:error, "Action name must be a string."} = Action.validate_name(123)
      assert {:error, "Action name must be a string."} = Action.validate_name(:atom)
      assert {:error, "Action name must be a string."} = Action.validate_name(%{})
      assert {:error, "Action name must be a string."} = Action.validate_name([])
    end

    test "accepts empty schema sentinel and Zoi schemas" do
      assert :ok = Action.validate_config_schema([])
      assert :ok = Action.validate_config_schema(Zoi.object(%{value: Zoi.integer()}))
    end

    test "rejects non-Zoi schemas" do
      assert {:error, "must be a Zoi schema"} = Action.validate_config_schema(%{})
    end

    test "rejects action schemas that cannot accept map-shaped data" do
      assert {:error, "must accept map-shaped action data"} =
               Action.validate_action_schema(Zoi.integer())

      module = unique_module("ScalarOutputSchemaAction")

      assert_raise CompileError, ~r/must accept map-shaped action data/, fn ->
        create_module(
          module,
          quote do
            use Jido.Action,
              name: "scalar_output_schema_action",
              output_schema: Zoi.integer()
          end
        )
      end
    end
  end

  describe "parameter validation" do
    test "validates required parameters" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               FullAction.validate_params(%{})

      assert message =~ "required"
      assert message =~ "a"
    end

    test "validates parameter types" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               FullAction.validate_params(%{a: "not an integer", b: 2})

      assert message =~ "expected integer"
    end

    test "preserves unknown parameters after validation" do
      assert {:ok, params} = FullAction.validate_params(%{a: 1, b: 2, trace_id: "trace-1"})
      assert params == %{a: 1, b: 2, trace_id: "trace-1"}
    end

    test "supports struct schemas when validating params" do
      params_module = unique_module("StructParams")
      action_module = unique_module("StructSchemaAction")

      create_module(
        params_module,
        quote do
          defstruct [:value]
        end
      )

      schema = Zoi.struct(params_module, [value: Zoi.integer()], coerce: true)

      create_module(
        action_module,
        quote do
          use Jido.Action,
            name: "struct_schema_action",
            schema: unquote(Macro.escape(schema))

          @impl true
          def run(params, _context), do: {:ok, params}
        end
      )

      assert {:ok, %{value: 42, extra: "kept"}} =
               action_module.validate_params(%{value: 42, extra: "kept"})
    end

    test "returns validation error for unsupported schema types" do
      module = unique_module("UnsupportedSchemaAction")

      create_module(
        module,
        quote do
          def schema, do: :not_a_zoi_schema
        end
      )

      assert {:error, %Jido.Action.Error.InvalidInputError{message: message, details: details}} =
               Action.validate_params_for(%{value: 1}, module)

      assert message == "Unsupported schema type"
      assert details.context == "Action"
      assert details.module == module
    end

    test "returns validation error for non-object Zoi schemas" do
      module = unique_module("ScalarSchemaAction")

      create_module(
        module,
        quote do
          def schema, do: Zoi.integer()
        end
      )

      assert {:error, %Jido.Action.Error.InvalidInputError{message: message, details: details}} =
               Action.validate_params_for(%{value: 1}, module)

      assert message =~ "expected integer"
      assert [%{path: [], code: :invalid_type}] = details.errors
    end
  end

  describe "action execution" do
    test "executes a valid action successfully" do
      assert {:ok, result} = FullAction.run(%{a: 5, b: 2}, %{})
      assert result.a == 5
      assert result.b == 2
      assert result.result == 7
    end
  end

  describe "error handling" do
    test "new returns an error tuple" do
      assert {:error, error} = Action.new()
      assert is_exception(error)
      assert Exception.message(error) =~ "Actions should not be defined at runtime"
    end

    test "new/1 returns an error tuple" do
      assert {:error, error} = Action.new(%{name: "runtime"})
      assert is_exception(error)
      assert Exception.message(error) =~ "Actions should not be defined at runtime"
    end
  end

  describe "output validation" do
    test "action with valid output schema validates successfully" do
      assert {:ok, result} =
               OutputSchemaAction.validate_output(%{result: "test", length: 4, extra: "data"})

      assert result.result == "test"
      assert result.length == 4
      assert result.extra == "data"
    end

    test "action with invalid output fails validation" do
      assert {:error, %Jido.Action.Error.InvalidInputError{message: message}} =
               OutputSchemaAction.validate_output(%{result: "test"})

      assert message =~ "required"
      assert message =~ "length"
    end

    test "action without output schema skips validation" do
      assert {:ok, result} = NoOutputSchemaAction.validate_output(%{anything: "goes"})
      assert result.anything == "goes"
    end

    test "action output validation rejects malformed output envelopes" do
      output = %Output{kind: :batch, value: :not_a_list, meta: %{}}

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               NoOutputSchemaAction.validate_output(output)
    end
  end

  defp field_keys(fields) when is_map(fields), do: Map.keys(fields)
  defp field_keys(fields) when is_list(fields), do: Keyword.keys(fields)

  def counted_options(counter) do
    Agent.update(counter, &(&1 + 1))
    [name: "counted_dynamic_options_action"]
  end
end
