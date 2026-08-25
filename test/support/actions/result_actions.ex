defmodule JidoActionTest.TestActions.ErrorAction do
  @moduledoc false
  use Jido.Action, name: "error_action"

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

defmodule JidoActionTest.TestActions.InvalidOutput do
  @moduledoc false
  use Jido.Action,
    name: "invalid_output",
    description: "Returns invalid output for validation tests",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value}, _context), do: {:ok, %{value: Integer.to_string(value)}}
end

defmodule JidoActionTest.TestActions.ExtrasAction do
  @moduledoc false
  use Jido.Action,
    name: "extras_action",
    description: "Returns a normal action output with extras",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value}, context) do
    {:ok, %{value: value}, %{trace_id: Map.get(context, :trace_id)}}
  end
end

defmodule JidoActionTest.TestActions.NoneExtrasAction do
  @moduledoc false
  use Jido.Action, name: "none_extras_action"

  def run(params, _context), do: {:ok, params, :none}
end

defmodule JidoActionTest.TestActions.UnsupportedResult do
  @moduledoc false
  use Jido.Action,
    name: "unsupported_result",
    description: "Returns an unsupported action result shape"

  def run(_params, _context), do: :not_a_result_tuple
end

defmodule JidoActionTest.TestActions.ThrowingAction do
  @moduledoc false
  use Jido.Action,
    name: "throwing_action",
    description: "Throws during execution"

  def run(_params, _context), do: throw(:thrown_value)
end

defmodule JidoActionTest.TestActions.StacktraceAction do
  @moduledoc false

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}

  def run(%{mode: :raise}, _context), do: raise_from_action()
  def run(%{mode: :throw}, _context), do: throw_from_action()
  def run(%{mode: :exit}, _context), do: exit_from_action()

  def raise_from_action, do: raise("stacktrace probe raised")
  def throw_from_action, do: throw(:stacktrace_probe_thrown)
  def exit_from_action, do: exit(:stacktrace_probe_exited)
end

defmodule JidoActionTest.TestActions.OutputEnvelopeAction do
  @moduledoc false
  use Jido.Action,
    name: "output_envelope_action",
    description: "Returns an explicit action output envelope",
    schema: Zoi.object(%{value: Zoi.integer()})

  def run(%{value: value}, _context) do
    {:ok, Jido.Action.Output.raw(%{value: value}, meta: %{source: :test})}
  end
end

defmodule JidoActionTest.TestActions.RawOutputAction do
  @moduledoc false
  use Jido.Action, name: "raw_output_action"

  def run(%{value: value}, _context), do: {:ok, value}
end

defmodule JidoActionTest.TestActions.RawOutputWithExtrasAction do
  @moduledoc false
  use Jido.Action, name: "raw_output_with_extras_action"

  def run(%{value: value}, _context), do: {:ok, value, %{effect: :already_ran}}
end

defmodule JidoActionTest.TestActions.ErrorWithExtrasAction do
  @moduledoc false
  use Jido.Action, name: "error_with_extras_action"

  def run(%{reason: reason}, _context), do: {:error, reason, %{ignored: true}}
  def run(_params, _context), do: {:error, :bad_with_extras, %{ignored: true}}
end

defmodule JidoActionTest.TestActions.ExceptionErrorAction do
  @moduledoc false
  use Jido.Action, name: "exception_error_action"

  def run(_params, _context) do
    {:error, Jido.Action.Error.execution_error("already wrapped", %{source: :test})}
  end
end

defmodule JidoActionTest.TestActions.AtomErrorAction do
  @moduledoc false
  use Jido.Action, name: "atom_error_action"

  def run(_params, _context), do: {:error, :bad_atom}
end

defmodule JidoActionTest.TestActions.TupleErrorAction do
  @moduledoc false
  use Jido.Action, name: "tuple_error_action"

  def run(_params, _context), do: {:error, {:bad, :tuple}}
end
