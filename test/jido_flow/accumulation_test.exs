defmodule Jido.Flow.AccumulationTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.{Codec, Component, Error, Registry, Step}

  defp document do
    registry = Registry.new!(%{"action" => {:action, UnloadedAction}, "schema" => {:schema, []}})

    flow =
      Flow.new!(
        name: "ordered",
        components: [Step.new!(name: "one", action: UnloadedAction)],
        output: %{}
      )

    {:ok, document} = Codec.encode(flow, registry)
    {document, registry}
  end

  test "after names preserve normalized order and error precedence" do
    names = ["last", :first] ++ Enum.map(1..128, &"name_#{&1}")
    assert {:ok, normalized} = Component.after_names(names)
    assert normalized == Enum.map(names, &to_string/1)

    assert {:error, %{message: "component after contains a duplicate", details: %{name: "first"}}} =
             Component.after_names([:first, "last", "first", "last"])

    assert {:error, %{message: "component after must contain component names"}} =
             Component.after_names([:first, "first", nil])

    assert {:error, %{message: "component after must be a proper list"}} =
             Component.after_names(["first" | :tail])
  end

  test "after validation has bounded reduction growth" do
    # Eight times the input permits twice the linear growth. This checks BEAM
    # work, not wall time, and catches repeated copies of the accumulated list.
    counts =
      for size <- [2048, 16_384] do
        names = Enum.map(1..size, &"name_#{&1}")

        Task.async(fn ->
          :erlang.garbage_collect()
          {:reductions, before} = Process.info(self(), :reductions)
          assert {:ok, ^names} = Component.after_names(names)
          {:reductions, after_count} = Process.info(self(), :reductions)
          after_count - before
        end)
        |> Task.await()
      end

    [small, large] = counts
    assert large < small * 16
  end

  test "Codec preserves broad values and ordered nested error groups" do
    {document, registry} = document()
    values = Enum.map(0..255, &[&1, &1 + 1])
    assert {:ok, %{output: ^values}} = Codec.diagnose(%{document | "output" => values}, registry)

    invalid =
      Enum.map(0..127, fn _ ->
        [
          %{"$ref" => %{"source" => "unsupported", "component" => 42, "path" => 42}},
          %{"$type" => "atom"}
        ]
      end)

    assert {:error, %Error.Invalid{errors: errors}} =
             Codec.diagnose(%{document | "output" => invalid}, registry)

    assert Enum.map(errors, & &1.details.path) ==
             Enum.flat_map(0..127, fn index ->
               Enum.map(["source", "component", "path"], &["output", index, 0, "$ref", &1]) ++
                 [["output", index, 1, "id"]]
             end)
  end

  test "Codec reports duplicate occurrences in source order" do
    {document, registry} = document()
    [step] = document["components"]
    names = ["first", "second", "second", "first", "first", "second"]
    components = Enum.map(names, &%{step | "name" => &1})

    assert {:error, %Error.Invalid{errors: errors}} =
             Codec.diagnose(%{document | "components" => components}, registry)

    assert Enum.map(errors, &{&1.details.name, &1.details.path}) ==
             Enum.map(Enum.with_index(Enum.drop(names, 2), 2), fn {name, index} ->
               {name, ["components", index, "name"]}
             end)
  end

  test "Codec preserves duplicate map key order and its first error" do
    {document, registry} = document()

    entries =
      Enum.map(["first", "second", "second", "first", "second"], &%{"key" => &1, "value" => 1})

    invalid = %{document | "output" => %{"$type" => "map", "entries" => entries}}

    assert {:error, %Error.Invalid{errors: [first | _] = errors}} =
             Codec.diagnose(invalid, registry)

    assert Enum.map(errors, & &1.details.path) ==
             Enum.map(2..4, &["output", "entries", &1, "key"])

    assert {:error, decoded_error} = Codec.decode(invalid, registry)
    assert decoded_error.message == first.message
    assert decoded_error.details == first.details
  end
end
