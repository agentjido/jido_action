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

  defmodule MissingValidateParams do
    @moduledoc false
    def run(params, _context), do: {:ok, params}
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

  defmodule ContextEcho do
    @moduledoc false
    use Action,
      name: "context_echo",
      description: "Echoes runtime context",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer(), trace_id: Zoi.string()})

    def run(%{value: value}, %{trace_id: trace_id}) do
      {:ok, %{value: value, trace_id: trace_id}}
    end
  end

  defmodule InvalidOutput do
    @moduledoc false
    use Action,
      name: "invalid_output",
      description: "Returns invalid output for validation tests",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context), do: {:ok, %{value: Integer.to_string(value)}}
  end

  defmodule ExtrasAction do
    @moduledoc false
    use Action,
      name: "extras_action",
      description: "Returns a normal action output with extras",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, context) do
      {:ok, %{value: value}, %{trace_id: Map.get(context, :trace_id)}}
    end
  end

  defmodule NoneExtrasAction do
    @moduledoc false
    use Action, name: "none_extras_action"

    def run(params, _context), do: {:ok, params, :none}
  end

  defmodule UnsupportedResult do
    @moduledoc false
    use Action,
      name: "unsupported_result",
      description: "Returns an unsupported action result shape"

    def run(_params, _context), do: :not_a_result_tuple
  end

  defmodule ThrowingAction do
    @moduledoc false
    use Action,
      name: "throwing_action",
      description: "Throws during execution"

    def run(_params, _context), do: throw(:thrown_value)
  end

  defmodule OutputEnvelopeAction do
    @moduledoc false
    use Action,
      name: "output_envelope_action",
      description: "Returns an explicit action output envelope",
      schema: Zoi.object(%{value: Zoi.integer()})

    def run(%{value: value}, _context) do
      {:ok, Jido.Action.Output.raw(%{value: value}, meta: %{source: :test})}
    end
  end

  defmodule RawOutputAction do
    @moduledoc false
    use Action, name: "raw_output_action"

    def run(%{value: value}, _context), do: {:ok, value}
  end

  defmodule RawOutputWithExtrasAction do
    @moduledoc false
    use Action, name: "raw_output_with_extras_action"

    def run(%{value: value}, _context), do: {:ok, value, %{effect: :already_ran}}
  end

  defmodule AtomValidationAction do
    @moduledoc false
    def validate_params(_params), do: {:error, :bad_params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  defmodule InvalidValidationResultAction do
    @moduledoc false
    def validate_params(_params), do: :ok
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  defmodule InvalidValidatedParamsAction do
    @moduledoc false
    def validate_params(_params), do: {:ok, 42}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, %{params: params}}
  end

  defmodule InvalidValidatedOutputAction do
    @moduledoc false
    def validate_params(params), do: {:ok, params}
    def validate_output(_output), do: {:ok, 42}
    def run(_params, _context), do: {:ok, %{value: 1}}
  end

  defmodule RaisingValidationAction do
    @moduledoc false
    def validate_params(_params), do: raise("validator failed")
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  defmodule RaisingOutputValidationAction do
    @moduledoc false
    def validate_params(params), do: {:ok, params}
    def validate_output(_output), do: raise("output validator failed")
    def run(params, _context), do: {:ok, params}
  end

  defmodule EchoParamsAction do
    @moduledoc false
    use Action, name: "echo_params_action"

    def run(params, _context), do: {:ok, params}
  end

  defmodule AnyEchoAction do
    @moduledoc false

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  defmodule DelayedEchoAction do
    @moduledoc false
    use Action, name: "delayed_echo_action"

    def run(%{sleep_ms: sleep_ms} = params, _context) when is_integer(sleep_ms) do
      Process.sleep(sleep_ms)
      {:ok, params}
    end
  end

  defmodule DelayedErrorAction do
    @moduledoc false
    use Action, name: "delayed_error_action"

    def run(%{sleep_ms: sleep_ms, message: message}, _context) when is_integer(sleep_ms) do
      Process.sleep(sleep_ms)
      {:error, message}
    end
  end

  defmodule KillingAction do
    @moduledoc false
    use Action, name: "killing_action"

    def run(_params, _context), do: Process.exit(self(), :kill)
  end

  defmodule RecorderAction do
    @moduledoc false
    use Action, name: "recorder_action"

    def run(params, %{test_pid: test_pid}) when is_pid(test_pid) do
      send(test_pid, {__MODULE__, params})
      {:ok, params}
    end

    def run(params, _context), do: {:ok, params}
  end

  defmodule ErrorWithExtrasAction do
    @moduledoc false
    use Action, name: "error_with_extras_action"

    def run(%{reason: reason}, _context), do: {:error, reason, %{ignored: true}}
    def run(_params, _context), do: {:error, :bad_with_extras, %{ignored: true}}
  end

  defmodule ExceptionErrorAction do
    @moduledoc false
    use Action, name: "exception_error_action"

    def run(_params, _context) do
      {:error, Jido.Action.Error.execution_error("already wrapped", %{source: :test})}
    end
  end

  defmodule RawExceptionErrorAction do
    @moduledoc false
    use Action, name: "raw_exception_error_action"

    def run(_params, _context), do: {:error, %RuntimeError{message: "raw exception"}}
  end

  defmodule AtomErrorAction do
    @moduledoc false
    use Action, name: "atom_error_action"

    def run(_params, _context), do: {:error, :bad_atom}
  end

  defmodule TupleErrorAction do
    @moduledoc false
    use Action, name: "tuple_error_action"

    def run(_params, _context), do: {:error, {:bad, :tuple}}
  end
end
