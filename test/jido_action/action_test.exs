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

    test "runtime compiled action keeps inline closure scope" do
      module = unique_module("RuntimeInlineClosureAction")

      create_module(
        module,
        quote do
          value = :outer
          item = :outer
          quoted_value = :outer

          use Jido.Action,
            name: "runtime_inline_closure_action",
            schema_bindings: [],
            schema:
              Zoi.object(%{
                value:
                  Zoi.integer()
                  |> Zoi.refine(fn value ->
                    _ast = quote(do: quoted_value)

                    if match?({:ok, item} when item > 0, {:ok, value}),
                      do: :ok,
                      else: {:error, "must be positive"}
                  end)
              })

          @outer_values {value, item, quoted_value}
          def outer_values, do: @outer_values
        end
      )

      assert module.outer_values() == {:outer, :outer, :outer}
      assert {:ok, %{value: 1}} = module.validate_params(%{value: 1})

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               module.validate_params(%{value: 0})
    end

    test "uses the last duplicate schema option consistently" do
      module = unique_module("RuntimeDuplicateSchemaAction")

      create_module(
        module,
        quote do
          use Jido.Action,
            name: "runtime_duplicate_schema_action",
            schema_bindings: [],
            schema: Zoi.object(%{first: Zoi.integer()}),
            schema:
              Zoi.object(%{
                second: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
              }),
            output_schema_bindings: [],
            output_schema: Zoi.object(%{first: Zoi.integer()}),
            output_schema:
              Zoi.object(%{
                second: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
              })
        end
      )

      assert {:ok, %{second: 1}} = module.validate_params(%{second: 1})
      assert {:ok, %{second: 2}} = module.validate_output(%{second: 2})
    end

    test "reports closure schemas that cannot be stored from dynamic options" do
      module = unique_module("RuntimeDynamicClosureSchemaAction")

      assert_raise CompileError,
                   ~r/closure-based :schema requires literal :schema_bindings/,
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

    test "keeps escapable caller values in closure schemas" do
      for {option, validator} <- [schema: :validate_params, output_schema: :validate_output] do
        module = unique_module("RuntimeCapturedClosureAction")

        schema_ast =
          quote do
            Zoi.object(%{
              value:
                Zoi.integer()
                |> Zoi.refine(fn value ->
                  if value > minimum, do: :ok, else: {:error, "too small"}
                end)
            })
          end

        bindings_option =
          if option == :schema, do: :schema_bindings, else: :output_schema_bindings

        opts_ast = [
          {:name, "runtime_captured_closure_action"},
          {bindings_option, [minimum: quote(do: minimum)]},
          {option, schema_ast}
        ]

        create_module(
          module,
          quote do
            minimum = 1
            use Jido.Action, unquote(opts_ast)
          end
        )

        assert {:ok, %{value: 2}} = apply(module, validator, [%{value: 2}])

        assert {:error, %Jido.Action.Error.InvalidInputError{}} =
                 apply(module, validator, [%{value: 1}])
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

    test "expands a literal schema macro once" do
      module = unique_module("CountedSchemaMacroAction")
      Process.put(:jido_schema_expansions, 0)

      create_module(
        module,
        quote do
          require Jido.ActionTest

          use Jido.Action,
            name: "counted_schema_macro_action",
            schema_bindings: [],
            schema:
              (
                require Jido.ActionTest
                Jido.ActionTest.counted_schema()
              )
        end
      )

      assert Process.get(:jido_schema_expansions) == 1
      assert {:ok, %{value: 1}} = module.validate_params(%{value: 1})
    after
      Process.delete(:jido_schema_expansions)
    end

    test "builds bound schemas once per cache generation" do
      module = unique_module("CachedSchemaAction")
      counter = Module.concat(module, Counter)
      counter_pid = start_supervised!({Agent, fn -> 0 end})
      Process.register(counter_pid, counter)

      on_exit(fn ->
        Jido.Action.SchemaStore.clear(module)
        :code.purge(module)
        :code.delete(module)
      end)

      assert {:module, ^module, bytecode, _term} =
               Module.create(
                 module,
                 quote do
                   counter = unquote(counter)

                   use Jido.Action,
                     name: "cached_schema_action",
                     schema_bindings: [counter: counter],
                     schema:
                       (
                         alias Jido.ActionTest, as: Helper
                         Helper.counted_closure_schema(counter)
                       )
                 end,
                 Macro.Env.location(__ENV__)
               )

      first_schema = module.schema()
      assert first_schema === module.schema()
      assert Agent.get(counter, & &1) == 1
      assert {:ok, %{value: 1}} = module.validate_params(%{value: 1})
      assert Agent.get(counter, & &1) == 1

      Jido.Action.SchemaStore.clear(module)
      :code.purge(module)
      :code.delete(module)
      assert {:module, ^module} = :code.load_binary(module, ~c"nofile", bytecode)

      assert Agent.get(counter, & &1) == 2
      assert {:ok, %{value: 2}} = module.validate_params(%{value: 2})
      assert Agent.get(counter, & &1) == 2
    end

    test "rejects non-portable schema bindings" do
      module = unique_module("NonPortableSchemaBindingAction")
      counter = Module.concat(module, Counter)
      counter_pid = start_supervised!({Agent, fn -> 0 end})
      Process.register(counter_pid, counter)

      assert_raise CompileError, ~r/:schema binding :owner is not portable/, fn ->
        create_module(
          module,
          quote do
            owner = self()
            counter = unquote(counter)

            use Jido.Action,
              name: "non_portable_schema_binding_action",
              schema_bindings: [counter: counter, owner: owner],
              schema: Jido.ActionTest.nonportable_schema(counter, owner)
          end
        )
      end

      assert Agent.get(counter, & &1) == 0
    end

    test "requires module attributes to use explicit schema bindings" do
      rejected_module = unique_module("DirectAttributeSchemaAction")

      assert_raise CompileError, ~r/:schema cannot read module attributes directly/, fn ->
        create_module(
          rejected_module,
          quote do
            @minimum 1

            use Jido.Action,
              name: "direct_attribute_schema_action",
              schema_bindings: [],
              schema:
                Zoi.object(%{
                  value:
                    Zoi.integer()
                    |> Zoi.refine(fn value ->
                      if value > @minimum, do: :ok, else: {:error, "too small"}
                    end)
                })
          end
        )
      end

      module = unique_module("BoundAttributeSchemaAction")

      create_module(
        module,
        quote do
          @minimum 1

          use Jido.Action,
            name: "bound_attribute_schema_action",
            schema_bindings: [minimum: @minimum],
            schema:
              Zoi.object(%{
                value:
                  Zoi.integer()
                  |> Zoi.refine(fn value ->
                    if value > minimum, do: :ok, else: {:error, "too small"}
                  end)
              })
        end
      )

      assert {:ok, %{value: 2}} = module.validate_params(%{value: 2})
    end

    test "shares the exact schema with the consumer on-load callback" do
      module = unique_module("ConsumerOnLoadAction")
      builder_counter = Module.concat(module, BuilderCounter)
      observer = Module.concat(module, Observer)

      start_supervised!(%{
        id: builder_counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: builder_counter]]}
      })

      start_supervised!(%{
        id: observer,
        start: {Agent, :start_link, [fn -> nil end, [name: observer]]}
      })

      on_exit(fn -> Jido.Action.SchemaStore.clear(module) end)

      create_module(
        module,
        quote do
          @on_load :consumer_on_load
          builder_counter = unquote(builder_counter)

          use Jido.Action,
            name: "consumer_on_load_action",
            schema_bindings: [builder_counter: builder_counter],
            schema: Jido.ActionTest.counted_closure_schema(builder_counter)

          def consumer_on_load do
            schema = schema()
            Agent.update(unquote(observer), fn nil -> schema end)
            :ok
          end
        end
      )

      assert Agent.get(builder_counter, & &1) == 1
      assert Agent.get(observer, & &1) === module.schema()
      assert {:ok, %{value: 1}} = module.validate_params(%{value: 1})
    end

    test "keeps the active schema when a replacement on-load callback fails" do
      module = unique_module("FailedReplacementOnLoadAction")
      recorder = Module.concat(module, Recorder)
      recorder_pid = start_supervised!({Agent, fn -> [] end})
      Process.register(recorder_pid, recorder)

      on_exit(fn -> Jido.Action.SchemaStore.clear(module) end)

      assert {:module, ^module, active_bytecode, _term} =
               Module.create(
                 module,
                 quote do
                   recorder = unquote(recorder)

                   use Jido.Action,
                     name: "failed_replacement_on_load_action",
                     schema_bindings: [recorder: recorder],
                     schema: Jido.ActionTest.recorded_closure_schema(recorder, :active)
                 end,
                 Macro.Env.location(__ENV__)
               )

      active_schema = module.schema()

      ExUnit.CaptureLog.capture_log(fn ->
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_raise CompileError, ~r/consumer @on_load returned/, fn ->
            create_module(
              module,
              quote do
                @on_load :reject_replacement
                recorder = unquote(recorder)

                use Jido.Action,
                  name: "failed_replacement_on_load_action",
                  schema_bindings: [recorder: recorder],
                  schema: Jido.ActionTest.recorded_closure_schema(recorder, :rejected)

                def reject_replacement do
                  _schema = schema()
                  {:error, :rejected}
                end
              end
            )
          end
        end)
      end)

      assert {:module, ^module} = :code.load_binary(module, ~c"nofile", active_bytecode)
      assert module.schema() === active_schema
      assert Agent.get(recorder, & &1) == [:active, :rejected]
    end

    test "shares the staged schema with earlier after-compile callbacks" do
      module = unique_module("ConsumerAfterCompileAction")
      builder_counter = Module.concat(module, BuilderCounter)
      observer = Module.concat(module, Observer)

      start_supervised!(%{
        id: builder_counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: builder_counter]]}
      })

      start_supervised!(%{
        id: observer,
        start: {Agent, :start_link, [fn -> nil end, [name: observer]]}
      })

      on_exit(fn -> Jido.Action.SchemaStore.clear(module) end)

      create_module(
        module,
        quote do
          builder_counter = unquote(builder_counter)
          @after_compile {Jido.ActionTest, :capture_schema_after_compile}

          use Jido.Action,
            name: "consumer_after_compile_action",
            schema_bindings: [builder_counter: builder_counter],
            schema: Jido.ActionTest.counted_closure_schema(builder_counter)

          def schema_observer, do: unquote(observer)
        end
      )

      assert Agent.get(builder_counter, & &1) == 1
      assert Agent.get(observer, & &1) === module.schema()
    end

    test "keeps nested Action schemas staged independently" do
      module = unique_module("NestedBoundAction")
      nested_module = Module.concat(module, Inner)
      recorder = Module.concat(module, Recorder)
      recorder_pid = start_supervised!({Agent, fn -> [] end})
      Process.register(recorder_pid, recorder)

      on_exit(fn ->
        Jido.Action.SchemaStore.clear(module)
        Jido.Action.SchemaStore.clear(nested_module)
      end)

      create_module(
        module,
        quote do
          recorder = unquote(recorder)

          use Jido.Action,
            name: "nested_bound_action",
            schema_bindings: [recorder: recorder],
            schema: Jido.ActionTest.recorded_closure_schema(recorder, :outer)

          defmodule Inner do
            recorder = unquote(recorder)

            use Jido.Action,
              name: "nested_inner_action",
              schema_bindings: [recorder: recorder],
              schema: Jido.ActionTest.recorded_closure_schema(recorder, :inner)
          end
        end
      )

      assert recorder |> Agent.get(& &1) |> Enum.sort() == [:inner, :outer]
      assert {:ok, %{value: 1}} = module.validate_params(%{value: 1})
      assert {:ok, %{value: 2}} = nested_module.validate_params(%{value: 2})
      assert recorder |> Agent.get(& &1) |> Enum.sort() == [:inner, :outer]
    end

    test "requires literal options for schema bindings" do
      module = unique_module("DynamicSchemaBindingsAction")

      assert_raise CompileError, ~r/schema bindings require literal Action options/, fn ->
        create_module(
          module,
          quote do
            opts = [
              name: "dynamic_schema_bindings_action",
              schema_bindings: [],
              schema:
                Zoi.object(%{
                  value: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
                })
            ]

            use Jido.Action, opts
          end
        )
      end
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

    test "invalid bound schema raises at compile time" do
      module = unique_module("InvalidBoundSchemaAction")

      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise CompileError, ~r/must accept map-shaped action data/, fn ->
          create_module(
            module,
            quote do
              @after_compile {Jido.ActionTest, :unexpected_after_compile}

              use Jido.Action,
                name: "invalid_bound_schema_action",
                schema_bindings: [],
                schema: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
            end
          )
        end
      end)

      refute Code.ensure_loaded?(module)
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

      invalid_options_module = unique_module("InvalidActionOptions")

      assert_raise CompileError, ~r/Action configuration validation failed/, fn ->
        create_module(
          invalid_options_module,
          quote do
            opts = 42
            use Jido.Action, opts
          end
        )
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

      assert {:error, "must accept map-shaped action data"} =
               Action.validate_action_schema(Zoi.lazy(fn -> Zoi.integer() end))

      assert :ok =
               Action.validate_action_schema(
                 Zoi.lazy(fn -> Zoi.object(%{value: Zoi.integer()}) end)
               )

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

    test "rejects scalar results from flexible action schemas" do
      module = unique_module("ScalarTransformAction")

      create_module(
        module,
        quote do
          use Jido.Action,
            name: "scalar_transform_action",
            schema_bindings: [],
            schema: Zoi.object(%{}) |> Zoi.transform(fn _params -> :invalid end),
            output_schema_bindings: [],
            output_schema: Zoi.object(%{}) |> Zoi.transform(fn _output -> :invalid end)
        end
      )

      assert {:error, %Jido.Action.Error.InvalidInputError{message: params_message}} =
               module.validate_params(%{})

      assert params_message == "Action validation must return a map"

      assert {:error, %Jido.Action.Error.InvalidInputError{message: output_message}} =
               module.validate_output(%{})

      assert output_message == "Action output validation must return a map"
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

  defp field_keys(fields), do: fields |> Map.new() |> Map.keys()

  def counted_options(counter) do
    Agent.update(counter, &(&1 + 1))
    [name: "counted_dynamic_options_action"]
  end

  defmacro counted_schema do
    Process.put(:jido_schema_expansions, Process.get(:jido_schema_expansions, 0) + 1)

    quote do
      Zoi.object(%{
        value: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
      })
    end
  end

  def counted_closure_schema(counter) do
    Agent.update(counter, &(&1 + 1))

    Zoi.object(%{
      value: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
    })
  end

  def capture_schema_after_compile(env, _bytecode) do
    schema = env.module.schema()
    Agent.update(env.module.schema_observer(), fn _current -> schema end)
  end

  def unexpected_after_compile(_env, _bytecode) do
    raise "consumer callback ran before Action schema verification"
  end

  def recorded_closure_schema(recorder, label) do
    Agent.update(recorder, &(&1 ++ [label]))

    Zoi.object(%{
      value: Zoi.integer() |> Zoi.refine(fn _value -> :ok end)
    })
  end

  def nonportable_schema(counter, owner) do
    Agent.update(counter, &(&1 + 1))

    Zoi.object(%{
      value:
        Zoi.integer()
        |> Zoi.refine(fn value ->
          send(owner, value)
          :ok
        end)
    })
  end
end
