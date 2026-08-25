defmodule JidoActionTest.Flow.Compiler.MapResultTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Flow.Compiler.MapResult

  test "builds and validates the exact plain Map result shape" do
    results = [
      %{item_id: "first", index: 0, output: %{}},
      %{item_id: "second", index: 1, output: Output.raw(%{})}
    ]

    errors = [
      %{item_id: "third", index: 2, error: Error.execution_error("failed")}
    ]

    aggregate = MapResult.new(results, errors)

    assert aggregate == %{
             kind: :jido_flow_map_result,
             results: results,
             errors: errors
           }

    assert {:ok, ^results, ^errors} = MapResult.validate(aggregate)
  end

  test "returns the existing error path for malformed Map results" do
    error = Error.execution_error("failed")

    invalid = [
      {%{kind: :jido_flow_map_result, results: [], errors: [], extra: true}, []},
      {%{kind: :jido_flow_map_result, results: :bad, errors: []}, []},
      {%{kind: :jido_flow_map_result, results: [%{}], errors: []}, [:results, 0]},
      {%{kind: :jido_flow_map_result, results: [], errors: [%{}]}, [:errors, 0]},
      {%{
         kind: :jido_flow_map_result,
         results: [%{item_id: "same", index: 0, output: %{}}],
         errors: [%{item_id: "same", index: 1, error: error}]
       }, []},
      {%{
         kind: :jido_flow_map_result,
         results: [
           %{item_id: "first", index: 1, output: %{}},
           %{item_id: "second", index: 0, output: %{}}
         ],
         errors: []
       }, [:results, 1]}
    ]

    for {aggregate, path} <- invalid do
      assert {:error, ^path} = MapResult.validate(aggregate)
    end

    assert {:error, []} = MapResult.validate(%{})
  end
end
