defmodule JidoTest.FlowScriptTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Script
  alias Runic.Workflow

  defmodule Add do
    use Jido.Action,
      name: "flow_script_add",
      schema:
        Zoi.object(%{
          value: Zoi.integer(),
          amount: Zoi.integer() |> Zoi.default(1)
        }),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
  end

  defmodule Double do
    use Jido.Action,
      name: "flow_script_double",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
  end

  test "compiles and runs a simple step flow from string module references" do
    source = """
    flow "math" do
      step "add", "#{inspect(Add)}", params: %{amount: 2}
      step "double", "#{inspect(Double)}", after: "add"
    end
    """

    assert {:ok, %Flow{name: "math"} = flow} = Script.compile(source)
    assert %{"add" => _, "double" => _} = Flow.components(flow)

    assert {:ok, result} = Exec.run(flow, %{value: 3})
    assert Workflow.raw_productions(result.workflow, "double") == [%{value: 10}]
  end

  test "accepts atom-looking names without interning user atoms" do
    flow_name = unique_atom_name("flow")
    step_name = unique_atom_name("step")

    source = """
    flow :#{flow_name} do
      step :#{step_name}, #{inspect(Add)}, params: %{amount: 4}
    end
    """

    assert {:ok, %Flow{name: ^flow_name} = flow} = Script.compile(source)
    assert Map.has_key?(Flow.components(flow), step_name)

    refute_existing_atom(flow_name)
    refute_existing_atom(step_name)
  end

  test "rejects unknown action modules without interning module atoms" do
    module_name = "JidoTest.FlowScriptMissing#{System.unique_integer([:positive])}"

    source = """
    flow "bad" do
      step "missing", "#{module_name}"
    end
    """

    assert {:error, %Error.InvalidInputError{} = error} = Script.compile(source)
    assert error.message == "action module must already exist"
    refute_existing_atom("Elixir." <> module_name)
  end

  test "rejects arbitrary call expressions as actions" do
    source = """
    flow "bad" do
      step "bad", System.cmd("echo", ["nope"])
    end
    """

    assert {:error, %Error.InvalidInputError{} = error} = Script.compile(source)
    assert error.message == "action must be a module alias or module name string"
  end

  test "rejects non-existing atom literals in params without interning them" do
    key = unique_atom_name("param")

    source = """
    flow "bad" do
      step "add", "#{inspect(Add)}", params: %{#{key}: 1}
    end
    """

    assert {:error, %Error.InvalidInputError{} = error} = Script.compile(source)
    assert error.message == "atom literal must already exist"
    assert error.details.atom == key
    refute_existing_atom(key)
  end

  defp unique_atom_name(prefix) do
    "#{prefix}_flow_script_untrusted_#{System.unique_integer([:positive])}"
  end

  defp refute_existing_atom(value) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end
end
