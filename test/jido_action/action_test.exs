defmodule Jido.ActionTest do
  use JidoTest.ActionCase, async: true
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias Jido.Action
  alias JidoTest.TestActions.Add
  alias JidoTest.TestActions.Divide
  alias JidoTest.TestActions.ErrorAction
  alias JidoTest.TestActions.FullAction
  alias JidoTest.TestActions.Multiply
  alias JidoTest.TestActions.NoOutputSchemaAction
  alias JidoTest.TestActions.NoSchema
  alias JidoTest.TestActions.OutputSchemaAction
  alias JidoTest.TestActions.Subtract

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

    test "executes basic calculator actions" do
      assert {:ok, %{value: 6}} = Add.run(%{value: 5, amount: 1}, %{})
      assert {:ok, %{value: 10}} = Multiply.run(%{value: 5, amount: 2}, %{})
      assert {:ok, %{value: 3}} = Subtract.run(%{value: 5, amount: 2}, %{})
      assert {:ok, %{value: 2.5}} = Divide.run(%{value: 5, amount: 2}, %{})
    end

    test "handles division by zero" do
      assert_raise RuntimeError, "Cannot divide by zero", fn ->
        Divide.run(%{value: 5, amount: 0}, %{})
      end
    end

    test "handles different error scenarios" do
      assert {:error, "Validation error"} =
               ErrorAction.run(%{error_type: :validation}, %{})

      assert_raise RuntimeError, "Runtime error", fn ->
        ErrorAction.run(%{error_type: :runtime}, %{})
      end
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

  describe "property-based tests" do
    property "valid action always returns a result for valid input" do
      check all(
              a <- integer(),
              b <- integer(1..1000)
            ) do
        params = %{a: a, b: b}
        assert {:ok, result} = FullAction.run(params, %{})
        assert result.a == a
        assert result.b == b
        assert result.result == a + b
      end
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
  end

  describe "nested exec warnings" do
    test "warns when run/2 calls Jido.Exec.run" do
      module = unique_module("QualifiedNestedExecAction")

      warning = compile_action(module, nested_run_body())

      assert warning =~ "nested Jido action execution inside #{inspect(module)}.run/2"
      assert warning =~ "Calling Jido.Exec.run inside an action makes composition opaque"
      assert warning =~ "@jido_allow_nested_exec true"
    end

    test "does not warn when nested execution is explicitly allowed" do
      module = unique_module("AllowedNestedExecAction")

      warning =
        compile_action(
          module,
          """
          @jido_allow_nested_exec true

          #{nested_run_body()}
          """
        )

      refute warning =~ "nested Jido action execution"
    end

    test "does not warn for helper functions outside run/2" do
      module = unique_module("HelperNestedExecAction")

      warning =
        compile_action(
          module,
          """
          def helper(params, context) do
            Jido.Exec.run(#{inspect(Add)}, params, context)
          end

          @impl true
          def run(params, _context) do
            {:ok, params}
          end
          """
        )

      refute warning =~ "nested Jido action execution"
    end
  end

  defp nested_run_body do
    """
    @impl true
    def run(params, context) do
      Jido.Exec.run(#{inspect(Add)}, params, context)
    end
    """
  end

  defp compile_action(module, body) do
    name =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Jido.Action, name: #{inspect(name)}

      #{body}
      end
      """)
    end)
  end

  defp field_keys(fields) when is_map(fields), do: Map.keys(fields)
  defp field_keys(fields) when is_list(fields), do: Keyword.keys(fields)
end
