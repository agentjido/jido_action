defmodule JidoTest.TestActions do
  @moduledoc false

  alias Jido.Action

  defmodule BasicAction do
    @moduledoc false
    use Action,
      name: "basic_action",
      description: "A basic action for testing",
      schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value}}
  end

  defmodule NoSchema do
    @moduledoc false
    use Action,
      name: "add_two",
      description: "Adds 2 to the input value"

    def run(%{value: value}, _context), do: {:ok, %{result: value + 2}}
    def run(_params, _context), do: {:ok, %{result: "No params"}}
  end

  defmodule OutputSchemaAction do
    @moduledoc false
    use Action,
      name: "output_schema_action",
      description: "Action that validates output with schema",
      schema: Zoi.object(%{input: Zoi.string()}),
      output_schema: Zoi.object(%{result: Zoi.string(), length: Zoi.integer()})

    def run(%{input: input}, _context) do
      {:ok, %{result: String.upcase(input), length: String.length(input), extra: "not validated"}}
    end
  end

  defmodule NoOutputSchemaAction do
    @moduledoc false
    use Action,
      name: "no_output_schema_action",
      description: "Action without output schema"

    def run(_params, _context), do: {:ok, %{anything: "goes", here: 123}}
  end

  defmodule FullAction do
    @moduledoc false
    use Action,
      name: "full_action",
      description: "A full action for testing",
      schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

    @impl true
    def run(params, _context) do
      result = params.a + params.b
      {:ok, Map.put(params, :result, result)}
    end
  end

  defmodule ErrorAction do
    @moduledoc false
    use Action, name: "error_action"

    def run(%{error_type: :validation}, _context), do: {:error, "Validation error"}

    def run(%{error_type: :argument}, _context) do
      raise ArgumentError, message: "Argument error"
    end

    def run(%{error_type: :runtime}, _context) do
      raise RuntimeError, message: "Runtime error"
    end

    def run(%{error_type: :custom}, _context), do: raise("Custom error")
    def run(%{error_type: :throw}, _context), do: throw("Action threw an error")
    def run(_params, _context), do: {:error, "Action failed"}
  end

  defmodule Add do
    @moduledoc false
    use Action,
      name: "add_one",
      description: "Adds 1 to the input value",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
  end

  defmodule MissingRun do
    @moduledoc false
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingValidateOutput do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
  end

  defmodule Multiply do
    @moduledoc false
    use Action,
      name: "multiply",
      description: "Multiplies the input value by 2",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(2)})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value * amount}}
  end

  defmodule Subtract do
    @moduledoc false
    use Action,
      name: "subtract",
      description: "Subtracts second value from first value",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)})

    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value - amount}}
  end

  defmodule Divide do
    @moduledoc false
    use Action,
      name: "divide",
      description: "Divides first value by second value",
      schema: Zoi.object(%{value: Zoi.float(), amount: Zoi.float() |> Zoi.default(2.0)})

    def run(%{value: value, amount: amount}, _context) when amount != 0 do
      {:ok, %{value: value / amount}}
    end

    def run(_params, _context), do: raise("Cannot divide by zero")
  end
end
