defmodule JidoActionTest.TestActions.BasicAction do
  @moduledoc false
  use Jido.Action,
    name: "basic_action",
    description: "A basic action for testing",
    schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value}, _context), do: {:ok, %{value: value}}
end

defmodule JidoActionTest.TestActions.NoSchema do
  @moduledoc false
  use Jido.Action,
    name: "add_two",
    description: "Adds 2 to the input value"

  def run(%{value: value}, _context), do: {:ok, %{result: value + 2}}
  def run(_params, _context), do: {:ok, %{result: "No params"}}
end

defmodule JidoActionTest.TestActions.OutputSchemaAction do
  @moduledoc false
  use Jido.Action,
    name: "output_schema_action",
    description: "Action that validates output with schema",
    schema: Zoi.object(%{input: Zoi.string()}),
    output_schema: Zoi.object(%{result: Zoi.string(), length: Zoi.integer()})

  def run(%{input: input}, _context) do
    {:ok, %{result: String.upcase(input), length: String.length(input), extra: "not validated"}}
  end
end

defmodule JidoActionTest.TestActions.NoOutputSchemaAction do
  @moduledoc false
  use Jido.Action,
    name: "no_output_schema_action",
    description: "Action without output schema"

  def run(_params, _context), do: {:ok, %{anything: "goes", here: 123}}
end

defmodule JidoActionTest.TestActions.FullAction do
  @moduledoc false
  use Jido.Action,
    name: "full_action",
    description: "A full action for testing",
    schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

  @impl true
  def run(params, _context) do
    result = params.a + params.b
    {:ok, Map.put(params, :result, result)}
  end
end

defmodule JidoActionTest.TestActions.Add do
  @moduledoc false
  use Jido.Action,
    name: "add_one",
    description: "Adds 1 to the input value",
    schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
end

defmodule JidoActionTest.TestActions.Multiply do
  @moduledoc false
  use Jido.Action,
    name: "multiply",
    description: "Multiplies the input value by 2",
    schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(2)})

  def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value * amount}}
end

defmodule JidoActionTest.TestActions.Divide do
  @moduledoc false
  use Jido.Action,
    name: "divide",
    description: "Divides first value by second value",
    schema: Zoi.object(%{value: Zoi.float(), amount: Zoi.float() |> Zoi.default(2.0)})

  def run(%{value: value, amount: amount}, _context) when amount != 0 do
    {:ok, %{value: value / amount}}
  end

  def run(_params, _context), do: raise("Cannot divide by zero")
end

defmodule JidoActionTest.TestActions.ContextEcho do
  @moduledoc false
  use Jido.Action,
    name: "context_echo",
    description: "Echoes runtime context",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer(), trace_id: Zoi.string()})

  def run(%{value: value}, %{trace_id: trace_id}) do
    {:ok, %{value: value, trace_id: trace_id}}
  end
end

defmodule JidoActionTest.TestActions.EchoParamsAction do
  @moduledoc false
  use Jido.Action, name: "echo_params_action"

  def run(params, _context), do: {:ok, params}
end
