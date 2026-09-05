defmodule JidoActionTest.Exec.FlowAdapterTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Flow.Error
  alias Jido.Flow.Error.InvalidDefinitionError

  defmodule CallCounter do
    def increment(key),
      do: Agent.update(__MODULE__, &Map.update(&1, key, 1, fn count -> count + 1 end))

    def value, do: Agent.get(__MODULE__, & &1)
  end

  defmodule CountingChildFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

    def flow do
      JidoActionTest.Exec.FlowAdapterTest.CallCounter.increment(:child)
      JidoActionTest.Fixtures.FlowAuthoring.math_flow!()
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
  end

  defmodule CountingRootFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

    def flow do
      JidoActionTest.Exec.FlowAdapterTest.CallCounter.increment(:root)

      Jido.Flow.new!(
        name: "counting_root",
        components: [
          Jido.Flow.Subflow.new!(
            name: "left",
            flow: JidoActionTest.Exec.FlowAdapterTest.CountingChildFlow,
            params: %{value: Jido.Flow.Ref.input(:value)}
          ),
          Jido.Flow.Subflow.new!(
            name: "right",
            flow: JidoActionTest.Exec.FlowAdapterTest.CountingChildFlow,
            params: %{value: Jido.Flow.Ref.input(:value)}
          )
        ],
        output: %{
          left: Jido.Flow.Ref.result("left"),
          right: Jido.Flow.Ref.result("right")
        }
      )
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
  end

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

  defmodule MissingDefinitionCallback do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  test "Exec compiles the exact flow/0 value" do
    assert {:ok, %Jido.Exec.Execution{}} = Exec.start(FlowWithoutCompiledCallback, %{value: 1})

    assert {:ok, %{value: 4}} = Exec.run(MismatchedCompiledFlow, %{value: 1})
    assert {:ok, %{value: 4}} = Exec.run(IgnoredCompiledFailureFlow, %{value: 1})

    assert {:ok, execution} = Exec.start(SourceMappedFlow, %{value: 1})

    assert execution.compiled.source_map == SourceMappedFlow.__jido_flow_source_map__()
  end

  test "Exec exposes the live native workflow and its compilation index" do
    assert {:ok, execution} = Exec.start(SourceMappedFlow, %{value: 1})

    assert %Runic.Workflow{} = workflow = Exec.workflow(execution)
    assert %Jido.Flow.Compiled{} = compiled = Exec.compiled(execution)
    assert workflow == execution.workflow
    assert compiled == execution.compiled
    assert compiled.source_map == SourceMappedFlow.__jido_flow_source_map__()
    assert Map.has_key?(compiled.component_index, "add_one")
  end

  test "one execution materializes each Flow module once" do
    start_supervised!(%{
      id: CallCounter,
      start: {Agent, :start_link, [fn -> %{} end, [name: CallCounter]]}
    })

    assert Exec.run(CountingRootFlow, %{value: 1}) ==
             {:ok, %{left: %{value: 4}, right: %{value: 4}}}

    assert CallCounter.value() == %{root: 1, child: 1}
  end

  test "Exec contains invalid, raised, and thrown module definitions" do
    for module <- [
          InvalidDefinitionFlow,
          InvalidSourceMapFlow,
          OwnedRaisingDefinitionFlow,
          RaisingDefinitionFlow,
          ThrowingDefinitionFlow
        ] do
      assert {:error, error} =
               Exec.start(module)

      assert Error.owned?(error)
    end

    assert {:error, %InvalidDefinitionError{details: %{reason: "missing flow/0"}}} =
             Exec.start(MissingDefinitionCallback)

    assert {:error,
            %InvalidDefinitionError{
              message: "Flow source map must be a map",
              details: %{flow: InvalidSourceMapFlow}
            }} = Exec.start(InvalidSourceMapFlow)
  end
end
