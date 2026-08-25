defmodule JidoActionTest.TestActions.MissingRun do
  @moduledoc false
  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
end

defmodule JidoActionTest.TestActions.MissingValidateParams do
  @moduledoc false
  def run(params, _context), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
end

defmodule JidoActionTest.TestActions.MissingValidateOutput do
  @moduledoc false
  def run(params, _context), do: {:ok, params}
  def validate_params(params), do: {:ok, params}
end

defmodule JidoActionTest.TestActions.AtomValidationAction do
  @moduledoc false
  def validate_params(_params), do: {:error, :bad_params}
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, params}
end

defmodule JidoActionTest.TestActions.InvalidValidationResultAction do
  @moduledoc false
  def validate_params(_params), do: :ok
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, params}
end

defmodule JidoActionTest.TestActions.InvalidValidatedParamsAction do
  @moduledoc false
  def validate_params(_params), do: {:ok, 42}
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, %{params: params}}
end

defmodule JidoActionTest.TestActions.InvalidValidatedOutputAction do
  @moduledoc false
  def validate_params(params), do: {:ok, params}
  def validate_output(_output), do: {:ok, 42}
  def run(_params, _context), do: {:ok, %{value: 1}}
end

defmodule JidoActionTest.TestActions.RaisingValidationAction do
  @moduledoc false
  def validate_params(_params), do: raise("validator failed")
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, params}
end

defmodule JidoActionTest.TestActions.RaisingOutputValidationAction do
  @moduledoc false
  def validate_params(params), do: {:ok, params}
  def validate_output(_output), do: raise("output validator failed")
  def run(params, _context), do: {:ok, params}
end

defmodule JidoActionTest.TestActions.StacktraceValidationAction do
  @moduledoc false

  def validate_params(%{mode: :input}), do: raise_from_input_validator()
  def validate_params(params), do: {:ok, params}

  def validate_output(%{mode: :output}), do: raise_from_output_validator()
  def validate_output(output), do: {:ok, output}

  def run(params, _context), do: {:ok, params}

  def raise_from_input_validator, do: raise("input validator stacktrace probe")
  def raise_from_output_validator, do: raise("output validator stacktrace probe")
end
