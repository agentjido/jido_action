defmodule JidoActionTest.Action.ValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Validation

  defmodule Params do
    @moduledoc false
    defstruct [:value]
  end

  describe "open_validate/3" do
    test "validates whole values for non-object Zoi schemas" do
      assert {:ok, 3} = Validation.open_validate(Zoi.integer(), 3, %{context: "Validation"})
    end

    test "keeps Zoi parsing behavior for map and struct schemas" do
      generic_map = Zoi.map(Zoi.string(), Zoi.integer())

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Validation.open_validate(generic_map, %{"value" => "bad"}, %{})

      coerced_object = Zoi.object(%{value: Zoi.integer()}, coerce: true)

      assert {:ok, %{"extra" => 2, value: 1}} =
               Validation.open_validate(coerced_object, %{"value" => 1, "extra" => 2}, %{})

      string_object = Zoi.object(%{"value" => Zoi.integer()})

      assert {:ok, %{"value" => 1}} =
               Validation.open_validate(string_object, %{"value" => 1}, %{})

      struct_schema = Zoi.struct(Params, %{value: Zoi.integer()})

      assert {:ok, %{value: 1}} =
               Validation.open_validate(struct_schema, %Params{value: 1}, %{})
    end

    test "keeps struct refinements when coercing open input" do
      schema =
        Zoi.struct(URI, %{scheme: Zoi.string()}, coerce: true)
        |> Zoi.refine(fn value ->
          if is_struct(value, URI), do: :ok, else: {:error, "expected URI struct"}
        end)

      assert {:ok, result} =
               Validation.open_validate(schema, %{scheme: "https", extra: "kept"}, %{})

      assert result.scheme == "https"
      assert result.extra == "kept"
    end

    test "preserves unknown fields in nested and wrapped object schemas" do
      nested_schema =
        Zoi.object(%{
          user: Zoi.object(%{name: Zoi.string()})
        })

      assert {:ok, %{trace: "trace", user: %{id: 7, name: "Ada"}}} =
               Validation.open_validate(
                 nested_schema,
                 %{trace: "trace", user: %{id: 7, name: "Ada"}},
                 %{}
               )

      object_schema = Zoi.object(%{value: Zoi.integer()})

      codec_schema =
        Zoi.codec(object_schema, object_schema,
          decode: &Function.identity/1,
          encode: &Function.identity/1
        )

      for wrapped_schema <- [
            Zoi.default(object_schema, %{value: 0}),
            Zoi.nullable(object_schema),
            Zoi.lazy(fn -> object_schema end),
            codec_schema
          ] do
        assert {:ok, %{extra: "kept", value: 1}} =
                 Validation.open_validate(
                   wrapped_schema,
                   %{extra: "kept", value: 1},
                   %{}
                 )
      end
    end
  end

  describe "open_validate_preserving_shape/3" do
    test "keeps structs and plain values in their validated shape" do
      schema = Zoi.struct(Params, %{value: Zoi.integer()})

      assert {:ok, %Params{value: 1}} =
               Validation.open_validate_preserving_shape(schema, %Params{value: 1}, %{})

      assert {:ok, 1} = Validation.open_validate_preserving_shape(Zoi.integer(), 1, %{})

      assert {:ok, %{value: 1}} =
               Validation.open_validate_preserving_shape(
                 Zoi.object(%{value: Zoi.integer()}),
                 %{value: 1},
                 %{}
               )

      assert {:ok, :unchanged} = Validation.open_validate_preserving_shape([], :unchanged, %{})
    end

    test "returns validation and unsupported-schema errors" do
      assert {:error, error} =
               Validation.open_validate_preserving_shape(Zoi.integer(), "bad", %{phase: :test})

      assert error.details.phase == :test
      assert is_list(error.details.errors)

      assert {:error, error} =
               Validation.open_validate_preserving_shape(:invalid, %{}, %{phase: :test})

      assert Exception.message(error) == "Unsupported schema type"
    end
  end

  test "opens nested collection and combination schemas" do
    cat = Zoi.object(%{type: Zoi.literal("cat"), name: Zoi.string()})
    dog = Zoi.object(%{type: Zoi.literal("dog"), name: Zoi.string()})

    schema =
      Zoi.object(%{
        pets: Zoi.array(Zoi.discriminated_union(:type, [cat, dog])),
        pair: Zoi.tuple({Zoi.object(%{value: Zoi.integer()}), Zoi.integer()}),
        merged:
          Zoi.intersection([
            Zoi.object(%{left: Zoi.integer()}),
            Zoi.object(%{right: Zoi.integer()})
          ])
      })

    value = %{
      pets: [%{type: "cat", name: "Mochi", extra: true}],
      pair: {%{value: 1, extra: true}, 2},
      merged: %{left: 1, right: 2, extra: true}
    }

    assert {:ok, validated} = Validation.open_validate(schema, value, %{})
    assert get_in(validated, [:pets, Access.at(0), :extra])
    assert validated.pair |> elem(0) |> Map.fetch!(:extra)
  end

  test "converts raised and thrown schema failures to structured errors" do
    raising = Zoi.lazy(fn -> raise "schema boom" end)
    throwing = Zoi.lazy(fn -> throw(:schema_boom) end)

    assert {:error, raised} = Validation.open_validate(raising, %{}, %{phase: :raised})
    assert Exception.message(raised) == "schema validation failed"
    assert raised.details.exception == RuntimeError
    assert raised.details.phase == :raised

    assert {:error, thrown} = Validation.open_validate(throwing, %{}, %{phase: :thrown})
    assert Exception.message(thrown) == "schema validation failed"
    assert thrown.details.failure_kind == :throw
    assert thrown.details.phase == :thrown
  end

  test "classifies Action-compatible schema containers" do
    map = Zoi.object(%{value: Zoi.integer()})
    any = Zoi.any()
    literal_map = Zoi.literal(%{value: 1})
    default = Zoi.default(map, %{value: 0})
    union = Zoi.union([map, Zoi.integer()])
    intersection = Zoi.intersection([map, map])

    codec =
      Zoi.codec(map, map,
        decode: &Function.identity/1,
        encode: &Function.identity/1
      )

    discriminated =
      Zoi.discriminated_union(:type, [
        Zoi.object(%{type: Zoi.literal("one")}),
        Zoi.object(%{type: Zoi.literal("two")})
      ])

    for schema <- [
          map,
          Zoi.struct(Params, %{value: Zoi.integer()}),
          any,
          literal_map,
          default,
          union,
          intersection,
          codec,
          discriminated,
          Zoi.lazy(fn -> map end),
          Zoi.lazy({__MODULE__, :map_schema, []})
        ] do
      assert Validation.action_schema?(schema)
    end

    refute Validation.action_schema?(Zoi.integer())
    refute Validation.action_schema?(Zoi.literal(:not_a_map))
    refute Validation.action_schema?(Zoi.union([Zoi.integer(), Zoi.string()]))
    refute Validation.action_schema?(Zoi.intersection([map, Zoi.integer()]))
  end

  def map_schema, do: Zoi.object(%{value: Zoi.integer()})
end
