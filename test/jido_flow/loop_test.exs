defmodule Jido.Flow.LoopTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow
  alias Jido.Flow.Condition
  alias Jido.Flow.ContractBundle
  alias Jido.Flow.Element
  alias Jido.Flow.Identity
  alias Jido.Flow.Loop
  alias Jido.Flow.Ref
  alias Jido.Flow.State
  alias JidoTest.TestActions.Add

  def inert_state_transform(_value, _opts), do: raise("State schema executed during inspection")

  defmodule NeverRun do
    use Jido.Action, name: "loop_never_run"

    @impl true
    def run(_params, _context), do: raise("Loop body executed during inspection")
  end

  describe "new/1" do
    test "builds one canonical Loop with nested State and scoped completion" do
      condition = %Condition{operator: :gte, operands: [Ref.state(:count), Ref.value(3)]}

      assert {:ok, loop} =
               Loop.new(
                 name: :count,
                 action: Add,
                 input: %{
                   count: Ref.state(:count),
                   prior: Ref.body_result(),
                   index: Ref.iteration_index()
                 },
                 state: [
                   schema: [],
                   initial: %{count: Ref.input(:count)},
                   update: %{count: Ref.body_result(:value)}
                 ],
                 completion: condition,
                 max_iterations: 5,
                 deps: [:seed]
               )

      assert loop.name == "count"
      assert loop.max_iterations == 5
      assert %State{version: 1} = loop.state
      assert loop.completion == condition
      assert loop.deps == ["seed"]
      assert Element.name(loop) == "count"
      assert Element.target_modules(loop) == [Add]

      assert Element.to_map(loop) == %{
               kind: :loop,
               name: "count",
               action: Add,
               input: %{
                 count: %{type: :state, path: [:count]},
                 prior: %{type: :body_result, path: []},
                 index: %{type: :iteration_index, path: []}
               },
               state: State.to_map(loop.state),
               completion: Condition.to_map(condition),
               max_iterations: 5,
               deps: ["seed"]
             }
    end

    test "collects result dependencies from every Loop phase" do
      loop =
        Loop.new!(
          name: :loop,
          action: Add,
          input: %{value: Ref.result(:body_input)},
          state: [
            schema: [],
            initial: Ref.result(:initial),
            update: %{value: Ref.result(:update), local: Ref.state(:value)}
          ],
          completion: %Condition{
            operator: :eq,
            operands: [Ref.result(:completion), Ref.value(true)]
          },
          max_iterations: 2,
          deps: [:explicit]
        )

      assert Loop.result_deps(loop) == [
               "body_input",
               "completion",
               "explicit",
               "initial",
               "update"
             ]
    end

    test "rejects malformed Loop contracts with exact bounded errors" do
      state = State.new!(schema: [], initial: %{}, update: %{})
      completion = %Condition{operator: :eq, operands: [Ref.value(1), Ref.value(1)]}

      cases = [
        {%{action: Add, state: state, completion: completion, max_iterations: 1},
         "loop name must be a non-empty string or atom", [:name]},
        {%{name: :bad, action: nil, state: state, completion: completion, max_iterations: 1},
         "loop body target must be a module atom", [:action]},
        {%{name: :bad, action: Add, state: state, completion: completion, max_iterations: 0},
         "loop max_iterations must be an integer from 1 to 10000", [:max_iterations]},
        {%{name: :bad, action: Add, state: state, completion: completion, max_iterations: 10_001},
         "loop max_iterations must be an integer from 1 to 10000", [:max_iterations]},
        {%{
           name: :bad,
           action: Add,
           state: state,
           completion: completion,
           max_iterations: 1,
           extra: true
         }, "unknown loop configuration key: :extra", [:extra]}
      ]

      for {attrs, message, path} <- cases do
        assert {:error, %InvalidInputError{message: ^message, details: %{path: ^path}}} =
                 Loop.new(attrs)
      end

      assert {:error,
              %InvalidInputError{
                message: "loop configuration must be a map",
                details: %{path: []}
              }} = Loop.new(:bad)
    end

    test "rejects collection-local refs in Loop scopes" do
      for {field, ref, path, scope} <- [
            {:input, Ref.item(), [:input], :loop_input},
            {:completion, %Condition{operator: :eq, operands: [Ref.accumulator(), 1]},
             [:completion, 0], :loop_completion}
          ] do
        attrs = %{
          name: :bad,
          action: Add,
          input: %{},
          state: [schema: [], initial: %{}, update: %{}],
          completion: %Condition{operator: :eq, operands: [1, 1]},
          max_iterations: 1
        }

        attrs = Map.put(attrs, field, ref)

        assert {:error,
                %InvalidInputError{
                  message: "flow expression contains a scoped ref outside its valid scope",
                  details: %{path: ^path, ref_type: _type, scope: ^scope}
                }} = Loop.new(attrs)
      end
    end

    test "extends Flow validation and iteration identity without changing Step identity" do
      seed = Jido.Flow.Node.new!(name: :seed, action: Add, input: %{})

      loop =
        Loop.new!(
          name: :loop,
          action: Add,
          state: [schema: [], initial: %{}, update: %{}],
          completion: %Condition{operator: :eq, operands: [Ref.value(true), Ref.value(true)]},
          max_iterations: 1,
          deps: [:seed]
        )

      flow = Flow.new!(name: "loop_flow", nodes: [loop, seed], return: Ref.result(:loop))
      digest = Identity.semantic_digest(flow)

      assert [^seed, ^loop] = Flow.canonical_nodes(flow.nodes)

      assert Identity.iteration_uuid(digest, "loop", 0) ==
               Identity.iteration_uuid(digest, "loop", 0)

      refute Identity.iteration_uuid(digest, "loop", 0) ==
               Identity.iteration_uuid(digest, "loop", 1)

      assert Identity.step_uuid(digest, "loop") == Identity.step_uuid(digest, "loop")
    end

    test "covers closed constructor, dependency, and provenance errors" do
      state = State.new!(schema: [], initial: %{}, update: %{})
      completion = %Condition{operator: :eq, operands: [Ref.value(true), Ref.value(true)]}

      base = %{
        name: :loop,
        action: Add,
        state: state,
        completion: completion,
        max_iterations: 1
      }

      assert_raise InvalidInputError, fn -> Loop.new!(Map.put(base, :max_iterations, 0)) end

      for {changes, message, path} <- [
            {%{name: " "}, "loop name must be a non-empty string or atom", [:name]},
            {%{state: nil}, "loop state is required", [:state]},
            {%{state: :bad}, "loop state configuration must be a map", [:state]},
            {%{completion: nil}, "loop completion is required", [:completion]},
            {%{deps: [:ok | :bad]}, "loop deps must be a proper list", [:deps]},
            {%{deps: :bad}, "loop deps must be a list", [:deps]},
            {%{deps: [1]}, "loop deps must be a list of step names", [:deps]},
            {%{deps: [" "]}, "loop deps must be a list of step names", [:deps]},
            {%{provenance: :bad}, "loop provenance must be a map", [:provenance]}
          ] do
        assert {:error, %InvalidInputError{message: ^message, details: %{path: ^path}}} =
                 base |> Map.merge(changes) |> Loop.new()
      end

      assert {:ok, %{input: %{}, deps: [], provenance: %{}}} =
               base
               |> Map.merge(%{input: nil, deps: nil, provenance: nil})
               |> Loop.new()
    end

    test "translates every body-input expression error without leaking values" do
      bad_path = %{Ref.input(:value) | path: [self()]}
      bad_ref = %{Ref.iteration_index() | node: "unexpected"}
      bad_result = %{Ref.result(:prior) | node: " "}

      for {input, message, detail} <- [
            {bad_path, "loop body input contains invalid ref path", :segment},
            {bad_ref, "loop body input contains invalid ref", :type},
            {URI.parse("https://example.com"), "loop body input contains unsupported expression",
             :expression},
            {bad_result, "loop body input must be static module data", nil}
          ] do
        attrs = [
          name: :bad_input,
          action: Add,
          input: input,
          state: [schema: [], initial: %{}, update: %{}],
          completion: %Condition{operator: :eq, operands: [1, 1]},
          max_iterations: 1
        ]

        assert {:error, %InvalidInputError{message: ^message, details: details}} = Loop.new(attrs)
        assert details.path == [:input]
        if detail, do: assert(Map.has_key?(details, detail))
      end
    end

    test "checks invalid body contracts and preserves requested provenance" do
      loop =
        Loop.new!(
          name: :unchecked,
          action: String,
          state: [schema: [], initial: %{}, update: %{}],
          completion: %Condition{operator: :eq, operands: [1, 1]},
          max_iterations: 1,
          provenance: %{source: :test}
        )

      assert {:error, %InvalidInputError{details: %{loop: "unchecked", target: String}}} =
               Loop.check(loop)

      assert Loop.to_map(loop, provenance: true).provenance == %{source: :test}
    end
  end

  describe "semantic and stored maps" do
    test "round-trips the exact semantic Loop and State records" do
      flow = loop_flow()
      semantic = Flow.to_map(flow)

      assert [loop] = semantic.nodes
      assert loop.kind == :loop
      assert loop.state.kind == :loop_state
      assert loop.state.schema === []
      assert loop.state.version == 1

      assert {:ok, loaded} = Flow.from_map(semantic)
      assert Flow.to_map(loaded) == semantic
      assert Identity.semantic_digest(loaded) == Identity.semantic_digest(flow)
    end

    test "uses bundle IDs for the body Action and State schema" do
      flow = loop_flow()
      {bundles, contracts} = loop_contracts()

      stored =
        Flow.to_map(flow,
          format: :stored,
          contracts: contracts,
          contract_bundles: bundles,
          state_schema_ids: %{"loop" => "state/v1"}
        )

      assert map_size(stored["contracts"]) == 4

      assert [
               %{
                 "kind" => "loop",
                 "action" => "add/v1",
                 "state" => %{
                   "kind" => "loop_state",
                   "version" => 1,
                   "schema" => "state/v1"
                 }
               }
             ] = stored["nodes"]

      assert {:ok, loaded} = Flow.from_map(stored, contract_bundles: bundles)
      assert Flow.to_map(loaded) == Flow.to_map(flow)
      assert Identity.semantic_digest(loaded) == Identity.semantic_digest(flow)
    end

    test "keeps State schema aliases outside semantic identity" do
      flow = loop_flow()
      {bundles, contracts} = loop_contracts()

      first =
        Flow.to_map(flow,
          format: :stored,
          contracts: contracts,
          contract_bundles: bundles,
          state_schema_ids: %{"loop" => "state/v1"}
        )

      alias_map =
        Flow.to_map(flow,
          format: :stored,
          contracts: contracts,
          contract_bundles: bundles,
          state_schema_ids: %{"loop" => "state/alias"}
        )

      refute first == alias_map
      assert {:ok, first_loaded} = Flow.from_map(first, contract_bundles: bundles)
      assert {:ok, alias_loaded} = Flow.from_map(alias_map, contract_bundles: bundles)
      assert Identity.semantic_digest(first_loaded) == Identity.semantic_digest(alias_loaded)
    end

    test "requires an exact State schema ID map for stored Loop writing" do
      flow = loop_flow()
      {bundles, contracts} = loop_contracts()
      base = [format: :stored, contracts: contracts, contract_bundles: bundles]

      error =
        assert_raise InvalidInputError,
                     "stored flow requires state_schema_ids for Loop schemas",
                     fn -> Flow.to_map(flow, base) end

      assert error.details == %{field: :state_schema_ids}

      error =
        assert_raise InvalidInputError,
                     "stored flow is missing a State schema identifier for Loop: \"loop\"",
                     fn -> Flow.to_map(flow, base ++ [state_schema_ids: %{}]) end

      assert error.details == %{field: :state_schema_ids, node: "loop"}

      error =
        assert_raise InvalidInputError,
                     "stored flow State schema identifiers contain an unknown Loop: \"other\"",
                     fn ->
                       Flow.to_map(
                         flow,
                         base ++
                           [state_schema_ids: %{"loop" => "state/v1", "other" => "state/v1"}]
                       )
                     end

      assert error.details == %{field: :state_schema_ids, node: "other"}

      error =
        assert_raise InvalidInputError, "stored flow state_schema_ids must be a map", fn ->
          Flow.to_map(flow, base ++ [state_schema_ids: []])
        end

      assert error.details == %{field: :state_schema_ids}

      error =
        assert_raise InvalidInputError, "duplicate flow map option: :state_schema_ids", fn ->
          Flow.to_map(
            flow,
            base ++
              [
                state_schema_ids: %{"loop" => "state/v1"},
                state_schema_ids: %{"loop" => "state/v1"}
              ]
          )
        end

      assert error.details == %{option: :state_schema_ids}
    end

    test "rejects unknown and mismatched State schema IDs" do
      flow = loop_flow()
      {bundles, contracts} = loop_contracts()
      base = [format: :stored, contracts: contracts, contract_bundles: bundles]

      error =
        assert_raise InvalidInputError, "unknown flow contract schema: \"missing/v1\"", fn ->
          Flow.to_map(flow, base ++ [state_schema_ids: %{"loop" => "missing/v1"}])
        end

      assert error.details == %{
               bundle: "bundle/v1",
               schema: "missing/v1",
               node: "loop",
               path: [:state_schema_ids, "loop"]
             }

      error =
        assert_raise InvalidInputError,
                     "flow Loop State schema reference does not match Loop semantics",
                     fn ->
                       Flow.to_map(
                         flow,
                         base ++ [state_schema_ids: %{"loop" => "other/v1"}]
                       )
                     end

      assert error.details == %{bundle: "bundle/v1", schema: "other/v1", node: "loop"}
    end

    test "rejects extra and missing semantic Loop and State fields" do
      semantic = loop_flow() |> Flow.to_map()

      for {path, field, record, message} <- [
            {[:nodes, Access.at(0)], :extra, :loop, "loop contains unknown field: :extra"},
            {[:nodes, Access.at(0)], :completion, :loop,
             "loop is missing required field: :completion"},
            {[:nodes, Access.at(0), :state], :extra, :loop_state,
             "loop state contains unknown field: :extra"},
            {[:nodes, Access.at(0), :state], :update, :loop_state,
             "loop state is missing required field: :update"}
          ] do
        malformed =
          if field == :extra do
            put_in(semantic, path, Map.put(get_in(semantic, path), field, true))
          else
            put_in(semantic, path, Map.delete(get_in(semantic, path), field))
          end

        assert {:error,
                %InvalidInputError{
                  message: ^message,
                  details: %{record: ^record, field: ^field}
                }} = Flow.from_map(malformed)
      end
    end

    test "rejects malformed stored State records before bundle resolution" do
      flow = loop_flow()
      {bundles, contracts} = loop_contracts()

      stored =
        Flow.to_map(flow,
          format: :stored,
          contracts: contracts,
          contract_bundles: bundles,
          state_schema_ids: %{"loop" => "state/v1"}
        )

      bad_version = put_in(stored, ["nodes", Access.at(0), "state", "version"], 2)

      assert {:error,
              %InvalidInputError{
                message: "unsupported loop state version: 2",
                details: %{version: 2, path: ["nodes", 0, "state"]}
              }} = Flow.from_map(bad_version, contract_bundles: bundles)

      bad_kind = put_in(stored, ["nodes", Access.at(0), "state", "kind"], "state")

      assert {:error,
              %InvalidInputError{
                message: "loop state kind must be loop_state",
                details: %{kind: "state", path: ["nodes", 0, "state"]}
              }} = Flow.from_map(bad_kind, contract_bundles: bundles)

      unknown_state =
        update_in(stored, ["nodes", Access.at(0), "state"], &Map.put(&1, "extra", true))

      assert {:error,
              %InvalidInputError{
                message: "loop state contains unknown field: \"extra\"",
                details: %{
                  record: :loop_state,
                  field: "extra",
                  path: ["nodes", 0, "state", "extra"]
                }
              }} = Flow.from_map(unknown_state, contract_bundles: bundles)
    end

    test "compiles a Loop as one inert public Step" do
      schema =
        Zoi.map()
        |> Zoi.transform({__MODULE__, :inert_state_transform, []})

      loop =
        Loop.new!(
          name: :inert,
          action: NeverRun,
          state: [schema: schema, initial: %{}, update: %{}],
          completion: %Condition{operator: :eq, operands: [Ref.value(true), Ref.value(true)]},
          max_iterations: 1
        )

      flow = Flow.new!(name: "inert_loop", nodes: [loop], return: Ref.result(:inert))
      semantic = Flow.to_map(flow)

      assert {:ok, decoded} = Flow.from_map(semantic)
      assert {:ok, %{"inert" => []}} = Flow.dependencies(decoded)
      assert {:ok, %{nodes: [%{kind: :loop}]}} = Flow.explain(decoded)
      assert {:ok, %{digest: digest}} = Flow.semantic_identity(decoded)
      assert is_binary(digest)

      assert {:ok, workflow} = Flow.compile(decoded)
      assert map_size(workflow.components) == 1
    end
  end

  defp loop_flow do
    loop =
      Loop.new!(
        name: :loop,
        action: Add,
        input: %{value: Ref.state(:value), index: Ref.iteration_index()},
        state: [
          schema: [],
          initial: %{value: Ref.input(:value)},
          update: %{value: Ref.body_result(:value)}
        ],
        completion: %Condition{
          operator: :gte,
          operands: [Ref.state(:value), Ref.value(3)]
        },
        max_iterations: 3
      )

    Flow.new!(name: "loop_map", nodes: [loop], return: Ref.result(:loop))
  end

  defp loop_contracts do
    contracts = %{
      bundle: "bundle/v1",
      input_schema: "input/v1",
      output_schema: "output/v1",
      action_registry: "actions/v1"
    }

    bundle =
      ContractBundle.new!(
        id: "bundle/v1",
        schemas: %{
          "input/v1" => [],
          "output/v1" => [],
          "state/v1" => [],
          "state/alias" => [],
          "other/v1" => [other: [type: :integer]]
        },
        action_registries: %{"actions/v1" => %{"add/v1" => Add}}
      )

    {%{"bundle/v1" => bundle}, contracts}
  end
end
