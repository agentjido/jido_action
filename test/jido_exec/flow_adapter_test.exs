defmodule JidoActionTest.Exec.FlowAdapterTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Jido.Executable
  alias Jido.Exec
  alias Jido.Exec.FlowAdapter
  alias Jido.Flow.Error
  alias Jido.Flow.Error.InvalidDefinitionError

  defmodule FlowWithoutCompiledCallback do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.FlowAuthoring.math_flow!()
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule MismatchedCompiledFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.FlowAuthoring.math_flow!()

    def compiled do
      Jido.Flow.new!(
        name: "mismatched_compiled_flow",
        components: [
          Jido.Flow.Step.new!(
            name: "wrong",
            action: JidoActionTest.Fixtures.Actions.Add,
            params: %{value: Jido.Flow.Ref.input(:value), amount: 100}
          )
        ],
        output: Jido.Flow.Ref.result("wrong")
      )
      |> Jido.Flow.compile!()
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule IgnoredCompiledFailureFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.FlowAuthoring.math_flow!()

    def compiled,
      do: {:error, Jido.Flow.Error.validation_error("compiled Flow is not available")}

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule SourceMappedFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.FlowAuthoring.math_flow!()

    def __jido_flow_source_map__ do
      %{[:components, "add_one"] => %{file: "source_mapped_flow.ex", line: 10, column: 3}}
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule InvalidSourceMapFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.FlowAuthoring.math_flow!()
    def __jido_flow_source_map__, do: :invalid
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(flow(), params, context)
  end

  defmodule InvalidDefinitionFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: :invalid
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule OwnedRaisingDefinitionFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: raise(Jido.Flow.Error.validation_error("owned Flow definition failure"))
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule RaisingDefinitionFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: raise("Flow definition failure")
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule ThrowingDefinitionFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: throw(:flow_definition_failure)
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule MissingRunFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: JidoActionTest.Fixtures.FlowAuthoring.math_flow!()
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  test "FlowAdapter compiles the exact flow/0 value" do
    assert {:ok, %Jido.Exec.Execution{}} =
             FlowAdapter.start(
               Executable.flow(FlowWithoutCompiledCallback),
               %{value: 1},
               %{},
               [],
               "without-compiled"
             )

    assert {:ok, %{value: 4}} = Exec.run(MismatchedCompiledFlow, %{value: 1})
    assert {:ok, %{value: 4}} = Exec.run(IgnoredCompiledFailureFlow, %{value: 1})

    assert {:ok, execution} =
             FlowAdapter.start(
               Executable.flow(SourceMappedFlow),
               %{value: 1},
               %{},
               [],
               "source-mapped"
             )

    assert execution.compiled.source_map == SourceMappedFlow.__jido_flow_source_map__()
  end

  test "FlowAdapter contains invalid, raised, and thrown module definitions" do
    for module <- [
          InvalidDefinitionFlow,
          InvalidSourceMapFlow,
          OwnedRaisingDefinitionFlow,
          RaisingDefinitionFlow,
          ThrowingDefinitionFlow
        ] do
      assert {:error, error} =
               FlowAdapter.start(Executable.flow(module), %{}, %{}, [], "invalid-definition")

      assert Error.owned?(error)
    end

    assert {:error, %InvalidDefinitionError{}} =
             FlowAdapter.validate(Executable.flow(MissingRunFlow))
  end

  test "FlowAdapter uses the target runner result contract" do
    assert {:ok, %{value: 8}} =
             FlowAdapter.run_target(
               Executable.flow(FlowWithoutCompiledCallback),
               %{value: 3},
               %{},
               "target-success",
               []
             )

    assert {:error, :execution, %InvalidDefinitionError{}} =
             FlowAdapter.run_target(
               Executable.flow(InvalidDefinitionFlow),
               %{value: 3},
               %{},
               "target-error",
               []
             )
  end
end
