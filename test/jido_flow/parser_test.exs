defmodule Jido.Flow.ParserTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Parser
  alias JidoTest.FlowFixtures
  alias JidoTest.TestActions.{Add, Multiply}

  describe "parse/2" do
    test "applies the stored source-byte limit before parsing" do
      limit = 1_048_576
      base = ~S[flow do
  step "echo", "add", with: %{value: value(1)}
  return result("echo")
end
#]
      exact = base <> :binary.copy("x", limit - byte_size(base))
      over_limit = exact <> "x"

      assert byte_size(exact) == limit

      assert {:ok, _flow} =
               Parser.parse(exact,
                 name: "stored_source_boundary",
                 profile: :stored,
                 actions: %{"add" => Add}
               )

      assert {:error,
              %InvalidInputError{
                message: "stored flow source exceeds resource limit",
                details: details
              }} =
               Parser.parse(over_limit,
                 name: "stored_source_over_limit",
                 profile: :stored,
                 actions: %{"add" => Add}
               )

      assert details == %{
               profile: :stored,
               resource: :source_bytes,
               limit: limit,
               actual: limit + 1,
               path: []
             }
    end

    test "does not intern source atoms when the byte precheck fails" do
      atom_name = "__jido_flow_source_atom_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      source = ":#{atom_name}\n" <> :binary.copy("x", 1_048_576)

      assert {:error, %InvalidInputError{message: "stored flow source exceeds resource limit"}} =
               Parser.parse(source, name: "too_large", profile: :stored)

      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    test "bounds stored quoted depth and collection width while trusted source stays exempt" do
      cases = [
        {:nesting_depth, nested_source(70)},
        {:collection_width, list_source(10_001)}
      ]

      for {resource, source} <- cases do
        assert {:error,
                %InvalidInputError{
                  message: "stored flow source exceeds resource limit",
                  details: details
                }} = Parser.parse(source, name: "bounded_source", profile: :stored)

        assert details.resource == resource
        assert details.profile == :stored
        assert is_list(details.path)

        assert {:ok, _flow} = Parser.parse(source, name: "trusted_source", profile: :trusted)
      end
    end

    test "bounds aggregate quoted term slots before DSL traversal" do
      inner = List.duplicate("0", 9_990) |> Enum.join(",")
      nested_lists = List.duplicate("[#{inner}]", 10) |> Enum.join(",")
      source = trusted_value_source("[#{nested_lists}]")

      assert byte_size(source) < 1_048_576

      assert {:error,
              %InvalidInputError{
                message: "stored flow source exceeds resource limit",
                details: details
              }} = Parser.parse(source, name: "term_slots", profile: :stored)

      assert details.resource == :term_count
      assert details.actual == 100_001
    end

    test "stored profile accepts novel string step names without existing atoms" do
      source = """
      flow do
        step "totally_novel_step_name", "add",
          with: %{value: input(:value), amount: value(1)}

        return result("totally_novel_step_name")
      end
      """

      assert {:ok, flow} =
               Parser.parse(source,
                 name: "stored_string_names",
                 profile: :stored,
                 actions: %{"add" => Add}
               )

      assert [%{name: "totally_novel_step_name"}] = Flow.to_map(flow).nodes
      assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{value: 3}, %{})
    end

    test "parses equal trusted and stored Map and Reduce source" do
      trusted_source = """
      flow do
        mapped = map :enrich, input(:items),
          run: JidoTest.TestActions.Add,
          with: %{value: item(:value), amount: value(1), index: item_index(), id: item_id()},
          on_error: :collect_errors

        summary = reduce :summarize, mapped,
          initial: value(%{total: 0}),
          run: JidoTest.TestActions.Multiply,
          with: %{value: accumulator(:total), amount: item(:value), id: item_id()},
          after: :enrich

        return summary
      end
      """

      stored_source = """
      flow do
        mapped = map "enrich", input(:items),
          run: "add",
          with: %{value: item(:value), amount: value(1), index: item_index(), id: item_id()},
          on_error: :collect_errors

        summary = reduce "summarize", mapped,
          initial: value(%{total: 0}),
          run: "multiply",
          with: %{value: accumulator(:total), amount: item(:value), id: item_id()},
          after: "enrich"

        return summary
      end
      """

      assert {:ok, trusted} = Parser.parse(trusted_source, name: "map_reduce_source")

      assert {:ok, stored} =
               Parser.parse(stored_source,
                 name: "map_reduce_source",
                 profile: :stored,
                 actions: %{"add" => Add, "multiply" => Multiply}
               )

      assert Flow.to_map(stored) == Flow.to_map(trusted)
      assert Flow.dependencies(stored) == Flow.dependencies(trusted)
      assert Flow.semantic_identity(stored) == Flow.semantic_identity(trusted)
    end

    test "parses equal trusted and stored Loop source through host registries" do
      trusted = """
      flow do
        counted = loop :count,
          run: JidoTest.TestActions.Add,
          with: %{value: state(:count), index: iteration_index()},
          state: [schema: "state/v1", initial: %{count: input(:count)}, update: %{count: body_result(:value)}],
          until: gte(state(:count), value(3)),
          max_iterations: 5
        return counted
      end
      """

      stored = String.replace(trusted, "JidoTest.TestActions.Add", ~s("add/v1"))
      common = [name: "loop_parser", state_schemas: %{"state/v1" => []}]

      assert {:ok, trusted_flow} = Parser.parse(trusted, common)

      assert {:ok, stored_flow} =
               Parser.parse(
                 stored,
                 common ++ [profile: :stored, actions: %{"add/v1" => Add}]
               )

      assert Flow.to_map(stored_flow) == Flow.to_map(trusted_flow)
      assert Flow.semantic_identity(stored_flow) == Flow.semantic_identity(trusted_flow)
    end

    test "rejects unknown Loop State schema IDs with bounded details" do
      source = """
      flow do
        loop :count,
          run: JidoTest.TestActions.Add,
          with: %{},
          state: [schema: "missing/v1", initial: %{}, update: %{}],
          repeat: 1
        return result(:count)
      end
      """

      assert {:error,
              %InvalidInputError{
                message: "unknown loop state schema identifier: \"missing/v1\"",
                details: %{schema: "missing/v1", node: "count", path: [:state, :schema]}
              }} = Parser.parse(source, name: "loop", state_schemas: %{"state/v1" => []})
    end

    test "rejects malformed State schema registries and stored module targets" do
      source = """
      flow do
        loop :count,
          run: JidoTest.TestActions.Add,
          with: %{},
          state: [schema: "state/v1", initial: %{}, update: %{}],
          repeat: 1
        return result(:count)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Parser.parse(source, name: "loop", state_schemas: :bad)

      assert message =~ "state_schemas"

      assert {:error, %InvalidInputError{message: stored_message}} =
               Parser.parse(source,
                 name: "loop",
                 profile: :stored,
                 actions: %{"add/v1" => Add},
                 state_schemas: %{"state/v1" => []}
               )

      assert stored_message =~ "stored flow action modules must use registered identifiers"
    end

    test "stored Map and Reduce parsing does not create atoms" do
      atom_name = "__jido_flow_map_atom_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      source = """
      flow do
        map "mapped", input(:items),
          run: "#{atom_name}",
          with: %{item: item()}

        return result("mapped")
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Parser.parse(source,
                 name: "unknown_stored_action",
                 profile: :stored,
                 actions: %{"add" => Add}
               )

      assert message == "unknown flow action identifier: #{inspect(atom_name)}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    test "stored Loop schema lookup does not create atoms" do
      schema_id = "__jido_flow_loop_schema_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(schema_id) end

      source = """
      flow do
        loop "count",
          run: "add",
          with: %{},
          state: [schema: "#{schema_id}", initial: %{}, update: %{}],
          repeat: 1
        return result("count")
      end
      """

      expected_message = "unknown loop state schema identifier: #{inspect(schema_id)}"

      assert {:error,
              %InvalidInputError{
                message: ^expected_message
              }} =
               Parser.parse(source,
                 name: "stored_loop_atom_safety",
                 profile: :stored,
                 actions: %{"add" => Add},
                 state_schemas: %{"state/v1" => []}
               )

      assert_raise ArgumentError, fn -> String.to_existing_atom(schema_id) end
    end

    test "rejects closed Map and Reduce source escape forms" do
      cases = [
        {:missing_run, "map :mapped, input(:items), with: %{item: item()}",
         "unsupported flow DSL map options"},
        {:duplicate_run,
         "map :mapped, input(:items), run: JidoTest.TestActions.Add, run: JidoTest.TestActions.Add, with: %{item: item()}",
         "unsupported flow DSL map options"},
        {:unknown_option,
         "map :mapped, input(:items), run: JidoTest.TestActions.Add, with: %{item: item()}, timeout: 10",
         "unsupported flow DSL map options"},
        {:computed_mode,
         "map :mapped, input(:items), run: JidoTest.TestActions.Add, with: %{item: item()}, on_error: value(:collect_errors)",
         "unsupported flow DSL map on_error"},
        {:anonymous_target,
         "map :mapped, input(:items), run: fn -> JidoTest.TestActions.Add end, with: %{item: item()}",
         "unsupported flow DSL action module"},
        {:capture_target,
         "map :mapped, input(:items), run: &JidoTest.TestActions.Add.run/2, with: %{item: item()}",
         "unsupported flow DSL action module"},
        {:pipe_collection,
         "map :mapped, input(:items) |> Enum.to_list(), run: JidoTest.TestActions.Add, with: %{item: item()}",
         "unsupported flow DSL expression"},
        {:remote_input,
         "map :mapped, input(:items), run: JidoTest.TestActions.Add, with: %{item: String.upcase(\"x\")}",
         "unsupported flow DSL expression"},
        {:invalid_local_arity,
         "map :mapped, input(:items), run: JidoTest.TestActions.Add, with: %{item: item(:a, :b)}",
         "unsupported flow DSL expression"},
        {:inline_block,
         "reduce :summary, input(:items), initial: value(%{}), run: JidoTest.TestActions.Add, with: %{item: item(), acc: accumulator()} do\n step :bad, JidoTest.TestActions.Add, with: %{}\n end",
         "unsupported flow DSL reduce options"}
      ]

      for {_kind, statement, expected_message} <- cases do
        source = "flow do\n#{statement}\nreturn value(%{})\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Parser.parse(source, name: "bad_map_reduce")

        assert message =~ expected_message
      end
    end

    test "rejects forward bindings and local refs outside Map and Reduce input" do
      cases = [
        {"map :mapped, later, run: JidoTest.TestActions.Add, with: %{item: item()}\nlater = step :loaded, JidoTest.TestActions.Add, with: %{}",
         "binding reference before it is bound"},
        {"map :mapped, item(), run: JidoTest.TestActions.Add, with: %{item: item()}",
         "flow expression contains a scoped ref outside its valid scope"},
        {"map :mapped, input(:items), run: JidoTest.TestActions.Add, with: %{acc: accumulator()}",
         "flow expression contains a scoped ref outside its valid scope"},
        {"reduce :summary, item(), initial: value(%{}), run: JidoTest.TestActions.Add, with: %{item: item(), acc: accumulator()}",
         "flow expression contains a scoped ref outside its valid scope"},
        {"reduce :summary, input(:items), initial: item_id(), run: JidoTest.TestActions.Add, with: %{item: item(), acc: accumulator()}",
         "flow expression contains a scoped ref outside its valid scope"},
        {"step :plain, JidoTest.TestActions.Add, with: %{item: item()}",
         "flow expression contains a scoped ref outside its valid scope"}
      ]

      for {statements, expected_message} <- cases do
        source = "flow do\n#{statements}\nreturn value(%{})\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Parser.parse(source, name: "bad_scope")

        assert message =~ expected_message
      end
    end

    test "parses the math milestone string to the same canonical map as builder syntax" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.math_source(),
                 name: "math_flow",
                 description: "Adds one and doubles the result"
               )

      assert Flow.to_map(flow) == FlowFixtures.math_canonical_map()
    end

    test "uses empty parser options by default" do
      assert {:error, %InvalidInputError{message: message}} =
               Parser.parse(FlowFixtures.math_source())

      assert message =~ "flow name must be a string"
    end

    test "keeps trusted parser profile as the default" do
      opts = [
        name: "math_flow",
        description: "Adds one and doubles the result",
        profile: :trusted
      ]

      assert {:ok, default_flow} =
               Flow.parse(FlowFixtures.math_source(), Keyword.delete(opts, :profile))

      assert {:ok, trusted_flow} = Flow.parse(FlowFixtures.math_source(), opts)
      assert Flow.to_map(trusted_flow) == Flow.to_map(default_flow)
    end

    test "rejects non-string source" do
      assert {:error, %InvalidInputError{message: message}} = Flow.parse(:not_source, name: "bad")
      assert message =~ "flow source must be a string"
    end

    test "rejects invalid Elixir syntax with source line metadata" do
      source = """
      flow do
        step :bad,
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "invalid flow source"
      assert Keyword.fetch!(details.line, :line) == 3
    end

    test "rejects source without a single flow block" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse("input(:value)", name: "bad")

      assert message =~ "flow source must contain a single flow do block"
      assert details.form == "input(:value)"
    end

    test "rejects invalid parser options before lowering" do
      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(FlowFixtures.math_source(), :not_options)

      assert message =~ "flow parser options must be a map or keyword list"
    end

    test "rejects unsupported parser profiles before lowering" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(FlowFixtures.math_source(), name: "bad", profile: :unsafe)

      assert message =~ "unsupported flow parser profile"
      assert details.profile == :unsafe
    end

    test "rejects invalid flow config supplied through parser options" do
      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(FlowFixtures.math_source(), name: " ")

      assert message =~ "Action name cannot be blank"
    end

    test "stored parser profile rejects source atoms that do not already exist" do
      atom_name = "__jido_flow_stored_new_atom_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      source = """
      flow do
        step :#{atom_name}, JidoTest.TestActions.Add, with: %{}
        return result(:#{atom_name})
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad", profile: :stored)

      assert message =~ "invalid flow source"
      assert message =~ "unsafe atom"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    end

    test "parses binding assignments, with input, and return by binding" do
      source = """
      flow do
        added = step :add_one, JidoTest.TestActions.Add, with: %{value: input(:value), amount: 1}
        doubled = step :double, JidoTest.TestActions.Multiply, with: added
        return doubled
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "binding_flow")
      assert [add_one, double] = Flow.to_map(flow).nodes
      assert add_one.input.value == %{type: :input, path: [:value]}
      assert add_one.input.amount == %{type: :value, value: 1}
      assert double.input == %{type: :result, node: "add_one", path: []}
      assert Flow.to_map(flow).return == %{type: :result, node: "double", path: []}
    end

    test "parses ordered Choice conditions through trusted and stored profiles" do
      trusted_source = """
      flow do
        step "classified", JidoTest.TestActions.Add, with: %{}

        routed = choose :route, after: "classified" do
          option "eq", when: eq(input("kind"), value("eq")), run: JidoTest.TestActions.Add, with: %{}
          option "neq", when: neq(input("kind"), value("neq")), run: JidoTest.TestActions.Add, with: %{}
          option "lt", when: lt(input("rank"), value(3)), run: JidoTest.TestActions.Add, with: %{}
          option "lte", when: lte(input("rank"), value(3)), run: JidoTest.TestActions.Add, with: %{}
          option "gt", when: gt(input("rank"), value(3)), run: JidoTest.TestActions.Add, with: %{}
          option "gte", when: gte(input("rank"), value(3)), run: JidoTest.TestActions.Add, with: %{}
          option "included", when: input("kind") in value(["one", "two"]), run: JidoTest.TestActions.Add, with: %{}
          option "all", when: all([eq(input("kind"), value("all")), gt(input("rank"), value(0))]), run: JidoTest.TestActions.Add, with: %{}
          option "any", when: any([eq(input("kind"), value("any")), lt(input("rank"), value(0))]), run: JidoTest.TestActions.Add, with: %{}
          option "not", when: not(eq(input("kind"), value("not"))), run: JidoTest.TestActions.Multiply, with: %{}
          otherwise run: JidoTest.TestActions.Add, with: %{}
        end

        return routed
      end
      """

      stored_source =
        trusted_source
        |> String.replace("JidoTest.TestActions.Multiply", ~s("multiply"))
        |> String.replace("JidoTest.TestActions.Add", ~s("add"))

      assert {:ok, trusted_flow} = Flow.parse(trusted_source, name: "choice_parser")

      assert {:ok, stored_flow} =
               Flow.parse(stored_source,
                 name: "choice_parser",
                 profile: :stored,
                 actions: %{add: Add, multiply: Multiply}
               )

      assert Flow.to_map(stored_flow) == Flow.to_map(trusted_flow)

      assert [
               %{name: "classified"},
               %{kind: :choice, options: options, fallback: %{action: Add}, deps: ["classified"]}
             ] =
               Flow.to_map(trusted_flow).nodes

      assert Enum.map(options, & &1.name) == [
               "eq",
               "neq",
               "lt",
               "lte",
               "gt",
               "gte",
               "included",
               "all",
               "any",
               "not"
             ]

      assert Enum.map(options, & &1.condition.operator) == [
               :eq,
               :neq,
               :lt,
               :lte,
               :gt,
               :gte,
               :in,
               :all,
               :any,
               :not
             ]
    end

    test "rejects malformed and executable Choice source before evaluation" do
      cases = [
        {:arbitrary_condition_call,
         "option :bad, when: System.system_time(), run: JidoTest.TestActions.Add, with: %{}"},
        {:anonymous_function,
         "option :bad, when: eq(input(:kind), fn -> :bad end), run: JidoTest.TestActions.Add, with: %{}"},
        {:unknown_operator,
         "option :bad, when: matches(input(:kind), value(:bad)), run: JidoTest.TestActions.Add, with: %{}"},
        {:missing_with,
         "option :bad, when: eq(input(:kind), value(:bad)), run: JidoTest.TestActions.Add"},
        {:duplicate_option,
         """
         option :same, when: eq(input(:kind), value(:one)), run: JidoTest.TestActions.Add, with: %{}
         option :same, when: eq(input(:kind), value(:two)), run: JidoTest.TestActions.Add, with: %{}
         """},
        {:missing_fallback,
         "option :bad, when: eq(input(:kind), value(:bad)), run: JidoTest.TestActions.Add, with: %{}"}
      ]

      for {_kind, statements} <- cases do
        source = """
        flow do
          choose :route do
            #{statements}
          end

          return result(:route)
        end
        """

        assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
        assert message =~ "unsupported flow DSL" or message =~ "choice"
      end
    end

    test "parses bound steps whose names derive from binding handles" do
      source = """
      flow do
        added = step JidoTest.TestActions.Add, with: %{value: input(:value), amount: value(1)}
        return added
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "derived_binding_name_flow")
      assert [%{name: "added", input: input}] = Flow.to_map(flow).nodes
      assert input.value == %{type: :input, path: [:value]}
      assert input.amount == %{type: :value, value: 1}
      assert Flow.to_map(flow).return == %{type: :result, node: "added", path: []}
      assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{value: 3}, %{})
    end

    test "parses structurally valid trusted flows without checking action modules" do
      missing_action = unique_module("MissingTrustedAction")

      source = """
      flow do
        step :missing, #{inspect(missing_action)}, with: %{}
        return result(:missing)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "unchecked_trusted_flow")
      assert [%{action: ^missing_action}] = Flow.to_map(flow).nodes

      assert {:error, %InvalidInputError{message: message, details: details}} = Flow.check(flow)
      assert message == "action module could not be loaded"
      assert details.node == "missing"
      assert details.action == missing_action
    end

    test "parses step annotations as provenance only" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.annotated_source(),
                 name: "annotated_flow",
                 description: "Annotates a step without changing semantics"
               )

      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
      assert [%{provenance: provenance}] = Flow.to_map(flow, provenance: true).nodes
      assert provenance.label == "Add one"
      assert provenance.tags == ["math", "example"]
      assert provenance.note == "Visible only in provenance"
      assert is_integer(provenance.line)
      assert is_integer(provenance.column)
    end

    test "stored parser profile resolves registered action identifiers" do
      assert {:ok, flow} =
               Flow.parse(FlowFixtures.stored_annotated_source(),
                 name: "annotated_flow",
                 description: "Annotates a step without changing semantics",
                 profile: :stored,
                 actions: %{"add" => JidoTest.TestActions.Add}
               )

      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
      assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{value: 3}, %{})

      assert [%{provenance: provenance}] = Flow.to_map(flow, provenance: true).nodes

      assert Map.take(provenance, [:label, :tags, :note]) == %{
               label: "Add one",
               tags: ["math", "example"],
               note: "Visible only in provenance"
             }
    end

    test "stored parser profile derives names for registered action identifiers" do
      source = """
      flow do
        added = step "add", with: %{value: input(:value), amount: value(1)}
        return added
      end
      """

      assert {:ok, flow} =
               Flow.parse(source,
                 name: "derived_name_flow",
                 description: "Derives node names from bindings",
                 profile: :stored,
                 actions: %{"add" => JidoTest.TestActions.Add}
               )

      assert [%{name: "added"}] = Flow.to_map(flow).nodes
      assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{value: 3}, %{})
    end

    test "stored parser profile accepts keyword action registries" do
      source = """
      flow do
        step :add_one, :add, with: %{value: input(:value), amount: value(1)}
        return result(:add_one)
      end
      """

      assert {:ok, flow} =
               Flow.parse(source,
                 name: "annotated_flow",
                 description: "Annotates a step without changing semantics",
                 profile: :stored,
                 actions: [add: JidoTest.TestActions.Add]
               )

      assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
    end

    test "stored parser profile rejects unregistered action identifiers" do
      source = """
      flow do
        step :add_one, "missing", with: %{}
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad", profile: :stored, actions: %{})

      assert message =~ "unknown flow action identifier"
      assert message =~ "missing"
    end

    test "stored parser profile rejects direct action module aliases" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, with: %{}
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source,
                 name: "bad",
                 profile: :stored,
                 actions: %{"add" => JidoTest.TestActions.Add}
               )

      assert message =~ "stored flow action modules must use registered identifiers"
    end

    test "stored parser profile rejects invalid action registries" do
      cases = [
        [:bad],
        %{123 => JidoTest.TestActions.Add},
        %{"add" => "not_module"},
        :bad
      ]

      for actions <- cases do
        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.parse(FlowFixtures.stored_annotated_source(),
                   name: "bad",
                   profile: :stored,
                   actions: actions
                 )

        assert message =~ "flow action registry must map string or atom identifiers to modules"
        assert details.actions == actions
      end
    end

    test "parses root list step input expressions" do
      source = """
      flow do
        step :echo, JidoTest.TestActions.EchoParamsAction, [input(:value), value(2), 3]
        return result(:echo)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "list_input_flow")
      assert [echo] = Flow.to_map(flow).nodes

      assert echo.input == [
               %{type: :input, path: [:value]},
               %{type: :value, value: 2},
               %{type: :value, value: 3}
             ]
    end

    test "parses projection-only select expressions inside maps" do
      source = """
      flow do
        loaded =
          step :load_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{
              quote: %{
                id: input(:quote_id),
                pricing: %{total: input([:items, 0, :price])}
              },
              tags: [input(:tag)]
            }

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{
              quote_id: select(loaded, [:quote, :id]),
              total: select(select(loaded, [:quote, :pricing]), :total),
              first_item_id: select(input(:items), [0, :id]),
              tenant_id: select(context(:tenant), :id),
              trace_id: context(:trace_id)
            }

        return select(audit, :total)
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "projection_flow")
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes

      assert audit_quote.input == %{
               quote_id: %{type: :result, node: "load_quote", path: [:quote, :id]},
               total: %{
                 type: :result,
                 node: "load_quote",
                 path: [:quote, :pricing, :total]
               },
               first_item_id: %{type: :input, path: [:items, 0, :id]},
               tenant_id: %{type: :context, path: [:tenant, :id]},
               trace_id: %{type: :context, path: [:trace_id]}
             }

      assert Flow.to_map(flow).return == %{type: :result, node: "audit_quote", path: [:total]}
    end

    test "rejects shape expressions" do
      source = """
      flow do
        step :load_quote, JidoTest.TestActions.EchoParamsAction,
          with: shape(%{id: input(:quote_id)})

        return result(:load_quote)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad_shape")

      assert message =~ "unsupported flow DSL expression"
    end

    test "parses explicit after targets in keyword step options" do
      source = """
      flow do
        loaded =
          step :load_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{id: input(:quote_id)}

        step :independent, JidoTest.TestActions.EchoParamsAction,
          with: %{event: "side"}

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            with: %{event: "quoted"},
            after: [:load_quote, loaded]

        return audit
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "explicit_after_flow")
      assert [load_quote, independent, audit_quote] = Flow.to_map(flow).nodes

      assert load_quote.deps == []
      assert independent.deps == []
      assert audit_quote.deps == ["load_quote"]
      assert audit_quote.input == %{event: %{type: :value, value: "quoted"}}
    end

    test "parses shaped return expressions" do
      source = """
      flow do
        added =
          step :add_one, JidoTest.TestActions.Add,
            with: %{value: input(:value), amount: value(1)}

        doubled =
          step :double, JidoTest.TestActions.Multiply,
            with: %{value: select(added, :value), amount: value(2)}

        return %{
          sum: select(added, :value),
          product: select(doubled, :value),
          original: input(:value),
          trace_id: context(:trace_id),
          literal: "ok"
        }
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "shaped_return_flow")

      assert Flow.to_map(flow).return == %{
               sum: %{type: :result, node: "add_one", path: [:value]},
               product: %{type: :result, node: "double", path: [:value]},
               original: %{type: :input, path: [:value]},
               trace_id: %{type: :context, path: [:trace_id]},
               literal: %{type: :value, value: "ok"}
             }

      assert {:ok, %{sum: 4, product: 8, original: 3, trace_id: "trace-1", literal: "ok"}} =
               Jido.Exec.run(flow, %{value: 3}, %{trace_id: "trace-1"})
    end

    test "parses after before with in keyword step options" do
      source = """
      flow do
        loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}

        audit =
          step :audit_quote, JidoTest.TestActions.EchoParamsAction,
            after: loaded,
            with: %{event: "quoted"}

        return audit
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "explicit_after_order_flow")
      assert [_load_quote, audit_quote] = Flow.to_map(flow).nodes
      assert audit_quote.deps == ["load_quote"]
    end

    test "parses static branch groups" do
      source = """
      flow do
        cart =
          step :load_cart, JidoTest.TestActions.EchoParamsAction,
            with: %{cart_id: input(:cart_id)}

        group do
          branch :alpha do
            priced =
              step :price_cart, JidoTest.TestActions.EchoParamsAction,
                with: cart
          end

          branch :beta do
            reserved =
              step :reserve_inventory, JidoTest.TestActions.EchoParamsAction,
                with: cart
          end
        end

        final =
          step :finalize, JidoTest.TestActions.EchoParamsAction,
            with: %{priced: priced, reserved: reserved}

        return final
      end
      """

      assert {:ok, flow} = Flow.parse(source, name: "static_group_flow")

      assert [load_cart, price_cart, reserve_inventory, finalize] = Flow.to_map(flow).nodes
      assert load_cart.deps == []
      assert price_cart.deps == ["load_cart"]
      assert reserve_inventory.deps == ["load_cart"]
      assert finalize.deps == ["price_cart", "reserve_inventory"]

      refute inspect(Flow.to_map(flow)) =~ "alpha"
      refute inspect(Flow.to_map(flow)) =~ "beta"

      assert [
               _load_cart_provenance,
               %{provenance: %{branch: :alpha}},
               %{provenance: %{branch: :beta}},
               _finalize_provenance
             ] = Flow.to_map(flow, provenance: true).nodes
    end

    test "rejects arbitrary local function calls outside the Flow subset" do
      source = """
      flow do
        arbitrary(:value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
      assert message =~ "unsupported flow DSL operation"
    end

    test "rejects remote calls except action module aliases in the action position" do
      source = """
      flow do
        step :bad, String.upcase("x"), %{value: input(:value)}
        return result(:bad, :value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
      assert message =~ "unsupported flow DSL action module"
    end

    test "rejects unsafe or unsupported quoted forms" do
      cases = [
        {:remote_call_with, "step :bad, JidoTest.TestActions.Add, with: System.system_time()"},
        {:dot_projection, "step :bad, JidoTest.TestActions.Add, with: added.value"},
        {:capture, "step :bad, JidoTest.TestActions.Add, %{value: &String.upcase/1}"},
        {:sigil, "step :bad, JidoTest.TestActions.Add, %{value: ~s(value)}"},
        {:module_attribute, "step :bad, JidoTest.TestActions.Add, %{value: @value}"},
        {:comprehension, "step :bad, JidoTest.TestActions.Add, %{value: for(x <- [1], do: x)}"},
        {:import, "import String"},
        {:require, "require Integer"},
        {:nested_defmodule, "defmodule NestedFlowModule do\nend"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"
        assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")
        assert message =~ "unsupported flow DSL"
      end
    end

    test "rejects unsupported step options" do
      cases = [
        {:bind, "step :add_one, JidoTest.TestActions.Add, %{value: input(:value)}, bind: :added"},
        {:trailing_after, "step :add_one, JidoTest.TestActions.Add, %{}, after: :other"},
        {:after_without_with, "step :add_one, JidoTest.TestActions.Add, after: :other"},
        {:unknown_keyword, "step :add_one, JidoTest.TestActions.Add, with: %{}, unknown: true"},
        {:duplicate_with,
         "step :add_one, JidoTest.TestActions.Add, with: %{}, with: %{other: input(:value)}"},
        {:duplicate_after,
         """
         step :load, JidoTest.TestActions.Add, with: %{}
         step :add_one, JidoTest.TestActions.Add, with: %{}, after: :load, after: :load
         """},
        {:missing_input, "step :add_one, JidoTest.TestActions.Add"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:add_one)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL step options"
      end
    end

    test "rejects computed step annotation values" do
      cases = [
        {:label, ~s|label: String.upcase("bad")|},
        {:tags, "tags: [System.system_time()]"},
        {:note, ~s|note: String.upcase("bad")|}
      ]

      for {_kind, option} <- cases do
        source = """
        flow do
          step :bad, JidoTest.TestActions.Add, with: %{}, #{option}
          return result(:bad)
        end
        """

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL"
      end
    end

    test "rejects invalid literal step annotation values" do
      cases = [
        {:label, "label: :bad"},
        {:note, "note: 123"},
        {:tags_keyword, "tags: [bad: :tag]"},
        {:tags_value, "tags: [1]"},
        {:tags_shape, "tags: :bad"}
      ]

      for {_kind, option} <- cases do
        source = """
        flow do
          step :bad, JidoTest.TestActions.Add, with: %{}, #{option}
          return result(:bad)
        end
        """

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL annotation"
      end
    end

    test "rejects unsupported branch group forms" do
      cases = [
        {:old_parallel_keyword,
         """
         parallel do
           branch :alpha do
             step :price_cart, JidoTest.TestActions.EchoParamsAction, with: %{}
           end
         end
         """, "unsupported flow DSL operation"},
        {:group_without_block, "group :bad", "unsupported flow DSL group"},
        {:branch_without_name,
         """
         group do
           branch do
             step :price_cart, JidoTest.TestActions.EchoParamsAction, with: %{}
           end
         end
         """, "unsupported flow DSL branch"},
        {:return_in_branch,
         """
         group do
           branch :alpha do
             return result(:price_cart)
           end
         end
         """, "group branches may contain only step operations"},
        {:nested_group,
         """
         group do
           branch :alpha do
             group do
               branch :nested do
                 step :price_cart, JidoTest.TestActions.EchoParamsAction, with: %{}
               end
             end
           end
         end
         """, "group branches may contain only step operations"},
        {:remote_call_in_branch,
         """
         group do
           branch :alpha do
             String.upcase("x")
           end
         end
         """, "unsupported flow DSL operation"}
      ]

      for {_kind, form, expected_message} <- cases do
        source = "flow do\n#{form}\nreturn result(:price_cart)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ expected_message
      end
    end

    test "rejects unsupported explicit after targets" do
      cases = [
        {:select, "after: select(loaded, :id)"},
        {:shape, "after: shape(%{})"},
        {:remote_call, "after: System.system_time()"},
        {:dot_projection, "after: loaded.value"},
        {:keyword_list, "after: [loaded: :bad]"}
      ]

      for {_kind, option} <- cases do
        source = """
        flow do
          loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
          step :audit_quote, JidoTest.TestActions.EchoParamsAction, with: %{}, #{option}
          return result(:audit_quote)
        end
        """

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL after target"
      end
    end

    test "rejects keyword lists as input expressions" do
      source = """
      flow do
        step :echo, JidoTest.TestActions.EchoParamsAction, with: [value: input(:value)]
        return result(:echo)
      end
      """

      assert {:error, %InvalidInputError{message: message}} =
               Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL expression"
    end

    test "rejects invalid binding assignment forms with source line metadata" do
      cases = [
        {:right_side, "added = input(:value)"},
        {:tuple_pattern, "{added, other} = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:list_pattern, "[added] = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:pin, "^added = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:nested, "added = doubled = step :add_one, JidoTest.TestActions.Add, with: %{}"},
        {:operator, "added + other"},
        {:local_call, "added()"},
        {:remote_call, "String.upcase(\"x\")"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:add_one)\nend"

        assert {:error, %InvalidInputError{message: message, details: details}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL"
        assert details.line == 2
      end
    end

    test "rejects unbound handles through lowerer validation" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, with: missing
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "unknown binding handle"
      assert details.binding == :missing
      assert details.step == "add_one"
    end

    test "rejects wildcard binding assignments through lowerer validation" do
      source = """
      flow do
        _ = step :add_one, JidoTest.TestActions.Add, with: %{value: input(:value)}
        return result(:add_one)
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "reserved binding alias"
      assert details.binding == :_
    end

    test "rejects local calls that look like variable alias references" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, %{value: var(:missing, :value)}
        return result(:add_one, :value)
      end
      """

      assert {:error, %InvalidInputError{message: message}} = Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL expression"
    end

    test "rejects unsupported projection source forms" do
      cases = [
        {:computed_map_value,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: System.system_time()}",
         "unsupported flow DSL expression"},
        {:computed_path,
         """
         loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
         step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: select(loaded, System.system_time())}
         """, "unsupported flow DSL expression"},
        {:dot_projection,
         """
         loaded = step :load_quote, JidoTest.TestActions.EchoParamsAction, with: %{}
         step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: loaded.value}
         """, "unsupported flow DSL expression"},
        {:value_source,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{x: select(value(%{}), :id)}",
         "select source must resolve to an input, context, or result ref"}
      ]

      for {_kind, form, expected_message} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ expected_message
      end
    end

    test "rejects unsupported context expressions" do
      cases = [
        {:missing_arg,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context()}"},
        {:extra_arg,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context(:a, :b)}"},
        {:computed_path,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context(System.system_time())}"},
        {:remote_call_path,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context(String.length(\"x\"))}"},
        {:keyword_path,
         "step :bad, JidoTest.TestActions.EchoParamsAction, with: %{trace_id: context([a: :b])}"}
      ]

      for {_kind, form} <- cases do
        source = "flow do\n#{form}\nreturn result(:bad)\nend"

        assert {:error, %InvalidInputError{message: message}} =
                 Flow.parse(source, name: "bad")

        assert message =~ "unsupported flow DSL expression"
      end
    end

    test "parses source as data and never executes it" do
      path =
        Path.join(
          System.tmp_dir!(),
          "jido_flow_parser_executed_#{System.unique_integer([:positive])}"
        )

      source = """
      flow do
        File.write!(#{inspect(path)}, "executed")
      end
      """

      assert {:error, %InvalidInputError{}} = Flow.parse(source, name: "bad")
      refute File.exists?(path)
    end

    test "includes source line metadata when available" do
      source = """
      flow do
        step :add_one, JidoTest.TestActions.Add, %{value: input(:value)}
        System.system_time()
      end
      """

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Flow.parse(source, name: "bad")

      assert message =~ "unsupported flow DSL operation"
      assert details.line == 3
    end
  end

  defp nested_source(depth) do
    value = Enum.reduce(1..depth, "0", fn _, nested -> "[#{nested}]" end)
    trusted_value_source(value)
  end

  defp list_source(width) do
    value = List.duplicate("0", width) |> Enum.join(",")
    trusted_value_source("[#{value}]")
  end

  defp trusted_value_source(value) do
    """
    flow do
      step :echo, JidoTest.TestActions.Add, with: %{value: value(#{value}), amount: 1}
      return result(:echo)
    end
    """
  end
end
