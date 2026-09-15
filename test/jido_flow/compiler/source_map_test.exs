defmodule JidoActionTest.Flow.Compiler.SourceMapTest do
  use ExUnit.Case, async: true

  alias Jido.Flow
  alias Jido.Flow.Error.InvalidDefinitionError

  test "compile option errors precede Flow validation and retain their details" do
    invalid_flow = %{flow() | output: nil}

    cases = [
      {:invalid, "Flow compile options must be a keyword list or source map", %{}},
      {[{:source_map, %{}}, :invalid],
       "Flow compile options must be a keyword list or source map", %{}},
      {[source_map: nil, source_map: %{}, unknown: true],
       "unknown Flow compile option: :source_map", %{option: :source_map}},
      {[source_map: nil, source_map: %{}], "unknown Flow compile option: :source_map",
       %{option: :source_map}},
      {[source_map: nil], "Flow source map must be a map", %{}},
      {[source_map: MapSet.new()], "Flow source map must be a map", %{}}
    ]

    for {opts, message, details} <- cases do
      assert {:error, %InvalidDefinitionError{} = error} = Flow.compile(invalid_flow, opts)
      assert error.message == message
      assert error.details == details
    end

    assert {:error, %InvalidDefinitionError{message: "Flow output is required"}} =
             Flow.compile(invalid_flow)
  end

  test "source paths precede locations and location fields keep their validation order" do
    flow = flow()
    path = [:components, "echo"]

    cases = [
      {:invalid, nil, "Flow source-map path must be a proper list", %{}},
      {[:components | :invalid], nil, "Flow source-map path must be a proper list", %{}},
      {[nil], nil, "Flow source-map path contains an invalid segment", %{}},
      {[<<255>>], nil, "Flow source-map path contains an invalid segment", %{}},
      {[-1], nil, "Flow source-map path contains an invalid segment", %{}},
      {[self()], nil, "Flow source-map path contains an invalid segment", %{}},
      {path, nil, "Flow source location must be a map", %{path: path}},
      {path, MapSet.new(), "Flow source location must be a map", %{path: path}},
      {path, %{extra: true, file: 1, line: 0, column: 0},
       "Flow source location contains an unknown field", %{path: path, field: :extra}},
      {path, %{file: <<255>>, line: 0, column: 0},
       "Flow source location file must be a valid UTF-8 string", %{path: path}},
      {path, %{file: 1}, "Flow source location file must be a valid UTF-8 string", %{path: path}},
      {path, %{line: 0, column: 0}, "Flow source location line must be a positive integer",
       %{path: path}},
      {path, %{line: 1, column: 0}, "Flow source location column must be a positive integer",
       %{path: path}}
    ]

    for {path, location, message, details} <- cases do
      assert {:error, %InvalidDefinitionError{} = error} = Flow.compile(flow, %{path => location})
      assert error.message == message
      assert error.details == details
    end
  end

  test "direct maps and keyword options preserve optional locations and valid path segments" do
    flow = flow()

    source_map = %{
      [] => %{},
      [:components, "écho", 0, false] => %{file: nil, line: nil, column: nil},
      [:output] => %{file: "flow.ex", line: 1, column: 2}
    }

    for opts <- [source_map, [source_map: source_map]] do
      assert {:ok, compiled} = Flow.compile(flow, opts)
      assert compiled.source_map == source_map
    end
  end

  defp flow do
    Flow.new!(
      name: "source_map",
      components: [
        Jido.Flow.Step.new!(
          name: "echo",
          action: JidoActionTest.Fixtures.Actions.EchoParamsAction
        )
      ],
      output: %{}
    )
  end
end
