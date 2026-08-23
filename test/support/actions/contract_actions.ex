defmodule JidoTest.TestActions.MissingRun do
  @moduledoc false
  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
end

defmodule JidoTest.TestActions.MissingValidateParams do
  @moduledoc false
  def run(params, _context), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
end

defmodule JidoTest.TestActions.MissingValidateOutput do
  @moduledoc false
  def run(params, _context), do: {:ok, params}
  def validate_params(params), do: {:ok, params}
end

defmodule JidoTest.TestActions.AtomValidationAction do
  @moduledoc false
  def validate_params(_params), do: {:error, :bad_params}
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, params}
end

defmodule JidoTest.TestActions.InvalidValidationResultAction do
  @moduledoc false
  def validate_params(_params), do: :ok
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, params}
end

defmodule JidoTest.TestActions.InvalidValidatedParamsAction do
  @moduledoc false
  def validate_params(_params), do: {:ok, 42}
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, %{params: params}}
end

defmodule JidoTest.TestActions.InvalidValidatedOutputAction do
  @moduledoc false
  def validate_params(params), do: {:ok, params}
  def validate_output(_output), do: {:ok, 42}
  def run(_params, _context), do: {:ok, %{value: 1}}
end

defmodule JidoTest.TestActions.RaisingValidationAction do
  @moduledoc false
  def validate_params(_params), do: raise("validator failed")
  def validate_output(output), do: {:ok, output}
  def run(params, _context), do: {:ok, params}
end

defmodule JidoTest.TestActions.RaisingOutputValidationAction do
  @moduledoc false
  def validate_params(params), do: {:ok, params}
  def validate_output(_output), do: raise("output validator failed")
  def run(params, _context), do: {:ok, params}
end
