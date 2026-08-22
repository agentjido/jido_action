defmodule Jido.Flow.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.Ref
  alias Jido.Flow.State

  describe "new/1" do
    test "builds a versioned state contract with scoped update refs" do
      assert {:ok, state} =
               State.new(
                 schema: [],
                 initial: %{count: Ref.input(:count)},
                 update: %{
                   count: Ref.body_result(:count),
                   prior: Ref.state(:count),
                   index: Ref.iteration_index()
                 }
               )

      assert state.version == 1
      assert state.schema == []
      assert state.initial == %{count: Ref.input(:count)}
      assert state.update.count == Ref.body_result(:count)

      assert State.to_map(state) == %{
               kind: :iterate_state,
               version: 1,
               schema: [],
               initial: %{count: %{type: :input, path: [:count]}},
               update: %{
                 count: %{type: :body_result, path: [:count]},
                 prior: %{type: :state, path: [:count]},
                 index: %{type: :iteration_index, path: []}
               }
             }
    end

    test "requires schema, initial, and update and rejects unknown keys" do
      cases = [
        {%{initial: %{}, update: %{}}, "iterator state schema is required", [:schema]},
        {%{schema: [], update: %{}}, "iterator state initial is required", [:initial]},
        {%{schema: [], initial: %{}}, "iterator state update is required", [:update]},
        {%{schema: [], initial: %{}, update: %{}, extra: true},
         "unknown iterator state configuration key: :extra", [:extra]},
        {%{version: 2, schema: [], initial: %{}, update: %{}},
         "unsupported iterator state version: 2", [:version]},
        {%{schema: [], initial: [1 | :tail], update: %{}},
         "iterator state initial must be a proper list", [:initial]}
      ]

      for {attrs, message, path} <- cases do
        assert {:error, %InvalidInputError{message: ^message, details: %{path: ^path}}} =
                 State.new(attrs)
      end

      assert {:error,
              %InvalidInputError{
                message: "iterator state configuration must be a map",
                details: %{path: [:state]}
              }} = State.new(:bad)
    end

    test "rejects iterator-local refs during initialization" do
      for ref <- [Ref.state(), Ref.iteration_index(), Ref.body_result()] do
        assert {:error,
                %InvalidInputError{
                  message: "flow expression contains a scoped ref outside its valid scope",
                  details: %{path: [:initial], ref_type: type, scope: :iterate_initial}
                }} = State.new(schema: [], initial: ref, update: %{})

        assert type == ref.type
      end
    end

    test "requires a static map-shaped schema" do
      assert {:error, %InvalidInputError{message: message, details: details}} =
               State.new(schema: Zoi.string(), initial: %{}, update: %{})

      assert message == "iterator state schema must accept map-shaped action data"
      assert details.path == [:schema]
    end

    test "raises through new!/1 and rejects non-static schemas" do
      assert_raise InvalidInputError, fn ->
        State.new!(schema: Zoi.string(), initial: %{}, update: %{})
      end

      assert {:error, %InvalidInputError{message: message, details: %{path: [:schema]}}} =
               State.new(schema: self(), initial: %{}, update: %{})

      assert message =~ "iterator state schema"
    end

    test "translates every State expression error" do
      bad_path = %{Ref.input(:value) | path: [self()]}
      bad_ref = %{Ref.iteration_index() | node: "unexpected"}
      bad_result = %{Ref.result(:prior) | node: " "}

      for {field, expression, message, detail} <- [
            {:initial, bad_path, "iterator state initial contains invalid ref path", :segment},
            {:update, bad_ref, "iterator state update contains invalid ref", :type},
            {:update, URI.parse("https://example.com"),
             "iterator state update contains unsupported expression", :expression},
            {:update, bad_result, "iterator state update must be static module data", nil}
          ] do
        attrs = %{schema: [], initial: %{}, update: %{}} |> Map.put(field, expression)

        assert {:error, %InvalidInputError{message: ^message, details: details}} =
                 State.new(attrs)

        assert details.path == [field]
        if detail, do: assert(Map.has_key?(details, detail))
      end
    end
  end
end
