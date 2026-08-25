defmodule JidoActionTest.IteratorFixtures.Increment do
  @moduledoc false
  use Jido.Action,
    name: "iterator_increment",
    schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()}),
    output_schema: Zoi.object(%{count: Zoi.integer()})

  @impl true
  def run(%{count: count, index: index}, context) do
    if is_pid(context[:test_pid]), do: send(context.test_pid, {__MODULE__, index})
    {:ok, %{count: count + 1}}
  end
end

defmodule JidoActionTest.IteratorFixtures.Envelope do
  @moduledoc false
  use Jido.Action,
    name: "iterator_envelope",
    schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()})

  @impl true
  def run(%{count: count}, _context) do
    {:ok, Jido.Action.Output.raw(%{count: count + 1}, meta: %{source: :iterate_test})}
  end
end

defmodule JidoActionTest.IteratorFixtures.FailsSecond do
  @moduledoc false
  use Jido.Action,
    name: "iterator_fails_second",
    schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()}),
    output_schema: Zoi.object(%{count: Zoi.integer()})

  @impl true
  def run(%{index: index} = params, context) do
    if is_pid(context[:test_pid]), do: send(context.test_pid, {__MODULE__, index})

    if index == 1 do
      {:error, "second body failed"}
    else
      {:ok, %{count: params.count + 1}}
    end
  end
end

defmodule JidoActionTest.IteratorFixtures.RetryableFailure do
  @moduledoc false
  use Jido.Action,
    name: "iterator_retryable_failure",
    schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()})

  @impl true
  def run(_params, _context) do
    {:error,
     Jido.Action.Error.execution_error("retryable body failed", %{
       retry: true,
       rejected_payload: %{secret: "must not leave the target boundary"}
     })}
  end
end

defmodule JidoActionTest.IteratorFixtures.ReturnedException do
  @moduledoc false
  use Jido.Action,
    name: "iterator_returned_exception",
    schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()})

  @impl true
  def run(_params, _context), do: {:error, RuntimeError.exception("returned body exception")}
end

defmodule JidoActionTest.IteratorFixtures.InvalidOutput do
  @moduledoc false
  use Jido.Action,
    name: "iterator_invalid_output",
    schema: Zoi.object(%{count: Zoi.integer(), index: Zoi.integer()}),
    output_schema: Zoi.object(%{count: Zoi.integer()})

  @impl true
  def run(_params, _context), do: {:ok, %{count: "bad"}}
end

defmodule JidoActionTest.IteratorFixtures.BrokenFlow do
  @moduledoc false
  @behaviour Jido.Executable

  @impl true
  def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

  def name, do: "iterator_broken_flow"
  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
  def flow, do: raise("broken nested Flow")

  def run(params, _context), do: {:ok, params}
end

defmodule JidoActionTest.IteratorFixtures.StateStruct do
  @moduledoc false
  @enforce_keys [:count]
  defstruct [:count]
end
