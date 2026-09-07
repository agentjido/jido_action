defmodule Jido.Flow.DSL.ExtensionTest.AddStep do
  @moduledoc false

  use Jido.Flow.Extension

  defmacro add_step(name, value, amount) do
    quote do
      step unquote(name),
        action: JidoActionTest.Fixtures.Actions.Add,
        params: %{value: unquote(value), amount: unquote(amount)}
    end
  end

  defmacro calculated_step(name, bindings, do: body) do
    quote do
      step unquote(name), unquote(bindings) do
        unquote(body)
      end
    end
  end

  defmacro dependent_step(name, dependency) do
    quote do
      step unquote(name),
        action: JidoActionTest.Fixtures.Actions.Add,
        params: %{value: 1, amount: 1},
        after: [unquote(dependency)]
    end
  end
end

defmodule Jido.Flow.DSL.ExtensionTest.ResultOutput do
  @moduledoc false

  use Jido.Flow.Extension

  defmacro result_output(name) do
    quote do
      output result(unquote(name))
    end
  end
end

defmodule Jido.Flow.DSL.ExtensionTest.ExtendedFlow do
  @moduledoc false

  alias Jido.Flow.DSL.ExtensionTest.{AddStep, ResultOutput}

  use Jido.Flow,
    name: "extended_flow",
    extensions: [AddStep, ResultOutput]

  flow do
    add_step("add", input(:value), value(2))
    result_output("add")
  end
end

defmodule Jido.Flow.DSL.ExtensionTest.PlainFlow do
  @moduledoc false

  use Jido.Flow, name: "extended_flow"

  flow do
    step "add",
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: input(:value), amount: value(2)}

    output result("add")
  end
end

defmodule Jido.Flow.DSL.ExtensionTest.InlineFlow do
  @moduledoc false

  use Jido.Flow,
    name: "extension_inline_flow",
    extensions: [Jido.Flow.DSL.ExtensionTest.AddStep]

  flow do
    calculated_step "double", value <- input(:value) do
      {:ok, %{value: double(value)}}
    end

    output result("double")
  end

  defp double(value), do: value * 2
end

defmodule Jido.Flow.DSL.ExtensionTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.DSL.ExtensionTest.{ExtendedFlow, InlineFlow, PlainFlow}

  test "a Flow extension lowers its macros to canonical Flow declarations" do
    assert [%Jido.Flow.Step{name: "add"}] = ExtendedFlow.flow().components
    assert Jido.Exec.run(ExtendedFlow, %{value: 3}) == {:ok, %{value: 5}}
  end

  test "extension declarations produce the same canonical Flow as core declarations" do
    assert ExtendedFlow.flow() == PlainFlow.flow()
  end

  test "an extension can expand to an inline Step that keeps the Flow owner scope" do
    assert [%Jido.Flow.Step{action: action}] = InlineFlow.flow().components
    assert action == InlineFlow.step_action("double")
    assert Jido.Exec.run(InlineFlow, %{value: 3}) == {:ok, %{value: 6}}
  end

  test "validation errors from extension declarations keep the call site" do
    module = unique_module("Source")

    source =
      "defmodule #{inspect(module)} do\n" <>
        "use Jido.Flow, name: \"extension_source\", extensions: [#{inspect(Jido.Flow.DSL.ExtensionTest.AddStep)}]\n" <>
        "flow do\n" <>
        "dependent_step \"add\", \"missing\"\n" <>
        "output result(\"add\")\n" <>
        "end\n" <>
        "end\n"

    error =
      assert_raise CompileError, fn -> Code.compile_string(source, "extension_source.ex") end

    assert error.file == "extension_source.ex"
    assert error.line == 4
  end

  test "Flow rejects an extension that does not use Jido.Flow.Extension" do
    module = unique_module("Invalid")

    source = """
    defmodule #{inspect(module)} do
      use Jido.Flow, name: "invalid_extension", extensions: [String]
      flow do
        output %{}
      end
    end
    """

    assert_raise CompileError, ~r/Flow extension must use Jido.Flow.Extension/, fn ->
      Code.compile_string(source, "invalid_flow_extension.ex")
    end
  end

  test "Flow rejects malformed and duplicate extension lists" do
    extension = Jido.Flow.DSL.ExtensionTest.AddStep

    cases = [
      {":invalid", ~r/Flow extensions must be a list/},
      {"[#{inspect(extension)}, #{inspect(extension)}]", ~r/duplicate Flow extension/}
    ]

    for {extensions, message} <- cases do
      module = unique_module("Options")

      source = """
      defmodule #{inspect(module)} do
        use Jido.Flow, name: "invalid_extensions", extensions: #{extensions}
        flow do
          output %{}
        end
      end
      """

      assert_raise CompileError, message, fn ->
        Code.compile_string(source, "invalid_flow_extensions.ex")
      end
    end
  end

  test "Jido.Flow.Extension rejects configuration options" do
    module = unique_module("Configured")

    source = """
    defmodule #{inspect(module)} do
      use Jido.Flow.Extension, imports: [String]
    end
    """

    assert_raise ArgumentError, ~r/Jido.Flow.Extension does not accept options/, fn ->
      Code.compile_string(source, "configured_flow_extension.ex")
    end
  end

  defp unique_module(prefix) do
    Module.concat(__MODULE__, "#{prefix}#{System.unique_integer([:positive])}")
  end
end
