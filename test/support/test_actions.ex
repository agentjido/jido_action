defmodule JidoTest.TestActions do
  @moduledoc false

  alias Jido.Action
  alias Jido.Action.Error

  defmodule FlowFunctions do
    @moduledoc false

    def identity(value), do: value
    def double(value), do: value * 2
    def sum(value, acc), do: value + acc
  end

  defmodule BasicAction do
    @moduledoc false
    use Action,
      name: "basic_action",
      description: "A basic action for testing",
      schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context) do
      {:ok, %{value: value}}
    end
  end

  defmodule NoSchema do
    @moduledoc false
    use Action,
      name: "add_two",
      description: "Adds 2 to the input value"

    def run(%{value: value}, _context), do: {:ok, %{result: value + 2}}

    # Allow no params
    def run(_params, _context), do: {:ok, %{result: "No params"}}
  end

  defmodule NoParamsAction do
    @moduledoc false
    use Action,
      name: "no_params_action",
      description: "A action with no parameters"

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

    def run(_params, _context) do
      {:ok, %{anything: "goes", here: 123}}
    end
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

    def run(%{error_type: :validation}, _context) do
      {:error, "Validation error"}
    end

    def run(%{error_type: :argument}, _context) do
      raise ArgumentError, message: "Argument error"
    end

    def run(%{error_type: :runtime}, _context) do
      raise RuntimeError, message: "Runtime error"
    end

    def run(%{error_type: :custom}, _context) do
      raise "Custom error"
    end

    def run(%{type: :throw}, _context) do
      throw("Action threw an error")
    end

    def run(_params, _context), do: {:error, "Exec failed"}
  end

  defmodule KilledAction do
    @moduledoc false
    use Action,
      name: "killed_action",
      description: "Kills the process"

    def run(_params, _context) do
      # Simulate some work before getting killed
      Process.sleep(50)
      Process.exit(self(), :kill)

      # This line will never be reached
      {:ok, %{result: "This should never be returned"}}
    end
  end

  defmodule Add do
    @moduledoc false
    use Action,
      name: "add_one",
      description: "Adds 1 to the input value",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{value: value + amount}}
    end
  end

  defmodule Double do
    @moduledoc false
    use Action,
      name: "double",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule SumJoined do
    @moduledoc false
    use Action,
      name: "sum_joined",
      schema: Zoi.object(%{input: Zoi.list(Zoi.map(Zoi.any(), Zoi.any()))}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{input: values}, _context) do
      total = Enum.reduce(values, 0, fn %{value: value}, acc -> acc + value end)
      {:ok, %{value: total}}
    end
  end

  defmodule Fail do
    @moduledoc false
    use Action,
      name: "fail",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{})

    def run(_params, _context), do: {:error, "boom"}
  end

  defmodule Flaky do
    @moduledoc false
    use Action,
      name: "flaky",
      schema: Zoi.object(%{key: Zoi.any()}),
      output_schema: Zoi.object(%{attempts: Zoi.integer()})

    def run(%{key: key}, _context) do
      attempts = :persistent_term.get({__MODULE__, key}, 0) + 1
      :persistent_term.put({__MODULE__, key}, attempts)

      if attempts < 2 do
        {:error, :transient_error}
      else
        {:ok, %{attempts: attempts}}
      end
    end
  end

  defmodule Slow do
    @moduledoc false
    use Action,
      name: "slow",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{done: Zoi.boolean()})

    def run(_params, _context) do
      Process.sleep(200)
      {:ok, %{done: true}}
    end
  end

  defmodule ContextEcho do
    @moduledoc false
    use Action,
      name: "context_echo",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema:
        Zoi.object(%{
          value: Zoi.integer(),
          static: Zoi.boolean() |> Zoi.optional(),
          runtime: Zoi.boolean() |> Zoi.optional()
        })

    def run(%{value: value}, context) do
      {:ok,
       %{
         value: value,
         static: Map.get(context, :static),
         runtime: Map.get(context, :runtime)
       }}
    end
  end

  defmodule WithDirective do
    @moduledoc false
    use Action,
      name: "with_directive",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value}, %{next: :flow}}
  end

  defmodule ErrorWithDirective do
    @moduledoc false
    use Action,
      name: "error_with_directive",
      schema: Zoi.object(%{}),
      output_schema: Zoi.object(%{})

    def run(_params, _context), do: {:error, :transient_error, %{next: :retry}}
  end

  defmodule InvalidFlowOutput do
    @moduledoc false
    use Action,
      name: "invalid_flow_output",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(_params, _context), do: {:ok, %{value: "bad"}}
  end

  defmodule InvalidOutputWithDirective do
    @moduledoc false
    use Action,
      name: "invalid_output_with_directive",
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(_params, _context), do: {:ok, %{value: "bad"}, %{next: :repair}}
  end

  defmodule OptionalInput do
    @moduledoc false
    use Action,
      name: "optional_input",
      schema:
        Zoi.object(%{
          value: Zoi.integer(),
          label: Zoi.string() |> Zoi.optional()
        }),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: value}}
  end

  defmodule ManualNoSchema do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ScalarSchema do
    @moduledoc false
    def schema, do: Zoi.integer()
    def output_schema, do: Zoi.string()
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ValidateParamsError do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(_params), do: {:error, Error.validation_error("bad params")}
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidValidateParamsReturn do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(_params), do: :ok
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidValidateOutputReturn do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(_output), do: :ok
  end

  defmodule UnexpectedReturn do
    @moduledoc false
    def run(_params, _context), do: :ok
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorExceptionAction do
    @moduledoc false
    def run(_params, _context), do: {:error, RuntimeError.exception("direct failure")}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorExceptionWithDirective do
    @moduledoc false
    def run(_params, _context),
      do: {:error, RuntimeError.exception("directive failure"), %{next: :retry}}

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorTupleAction do
    @moduledoc false
    def run(_params, _context), do: {:error, {:bad, :shape}}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorWithEmptyDirective do
    @moduledoc false
    def run(_params, _context), do: {:error, :empty_directive, []}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule EmptyDirective do
    @moduledoc false
    def run(params, _context), do: {:ok, params, []}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule RaisingAction do
    @moduledoc false
    def run(_params, _context), do: raise("boom")
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule ErrorMapAction do
    @moduledoc false
    def run(_params, _context), do: {:error, %{message: "mapped failure", code: :mapped}}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
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

  defmodule NotAnAction do
    @moduledoc false
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule Multiply do
    @moduledoc false
    use Action,
      name: "multiply",
      description: "Multiplies the input value by 2",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(2)})

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{value: value * amount}}
    end
  end

  defmodule Subtract do
    @moduledoc false
    use Action,
      name: "subtract",
      description: "Subtracts second value from first value",
      schema: Zoi.object(%{value: Zoi.integer(), amount: Zoi.integer() |> Zoi.default(1)})

    def run(%{value: value, amount: amount}, _context) do
      {:ok, %{value: value - amount}}
    end
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

    def run(_, _context) do
      raise "Cannot divide by zero"
    end
  end

  defmodule StreamingAction do
    @moduledoc false
    use Action,
      name: "streaming_action",
      description: "Showcases streaming or chunked data processing",
      schema:
        Zoi.object(%{
          chunk_size: Zoi.integer() |> Zoi.default(10),
          total_items: Zoi.integer() |> Zoi.default(100)
        })

    def run(%{chunk_size: chunk_size, total_items: total_items}, _context) do
      stream =
        1
        |> Stream.iterate(&(&1 + 1))
        |> Stream.take(total_items)
        |> Stream.chunk_every(chunk_size)
        |> Stream.map(fn chunk ->
          # Simulate processing time
          Process.sleep(10)
          Enum.sum(chunk)
        end)

      {:ok, %{stream: stream}}
    end
  end

  defmodule IOAction do
    @moduledoc """
    Test action module that demonstrates various IO operations.

    Used for testing IO-related functionality within actions.
    """

    use Action,
      name: "io_action",
      description: "Showcases various IO operations",
      schema:
        Zoi.object(%{
          input: Zoi.any() |> Zoi.default(%{foo: "bar"}),
          operation: Zoi.enum([:puts, :inspect, :write])
        })

    @impl true
    def run(%{input: _input, operation: :inspect} = params, _context) do
      # credo:disable-for-next-line Credo.Check.Warning.IoInspect
      IO.inspect(params, label: "IOAction")
      {:ok, params}
    end

    @impl true
    def run(%{input: input, operation: :puts}, _context) do
      IO.puts(input)
      {:ok, %{input: input}}
    end

    @impl true
    def run(%{input: input, operation: :write}, _context) do
      IO.write(input)
      {:ok, %{input: input}}
    end
  end
end
