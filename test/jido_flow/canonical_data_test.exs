defmodule JidoActionTest.Flow.CanonicalDataTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias JidoActionTest.Fixtures.Actions.Add

  test "constructs the canonical Flow data" do
    load =
      Step.new!(
        name: "load",
        action: Add,
        params: %{value: Ref.input(:value), amount: 1},
        after: [],
        meta: %{label: "Load"}
      )

    save =
      Step.new!(
        name: "save",
        action: Add,
        params: %{value: Ref.result("load", :value), amount: 1},
        after: ["audit"],
        meta: %{}
      )

    audit =
      Step.new!(
        name: "audit",
        action: Add,
        params: %{value: Ref.input(:value), amount: 0},
        after: [],
        meta: %{}
      )

    assert {:ok,
            %Flow{
              name: "canonical",
              components: [^load, ^save, ^audit],
              output: %Ref{source: :result, component: "save", path: []}
            } = flow} =
             Flow.new(
               name: "canonical",
               components: [load, save, audit],
               output: Ref.result("save")
             )

    assert save.after == ["audit"]

    assert {:ok,
            %{
              "load" => %{after: [], references: [], effective: []},
              "save" => %{
                after: ["audit"],
                references: ["load"],
                effective: ["audit", "load"]
              },
              "audit" => %{after: [], references: [], effective: []}
            }} = Flow.dependencies(flow)
  end
end
