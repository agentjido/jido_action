defmodule JidoTest.ExecFixtures.ActionWithFlowFunction do
  @moduledoc false
  use Jido.Action, name: "action_with_flow_function"

  def flow, do: :not_a_flow_artifact
  def run(params, _context), do: {:ok, Map.put(params, :executed_as, :action)}
end

defmodule JidoTest.ExecFixtures.ListOutputAction do
  @moduledoc false
  use Jido.Action, name: "list_output_action"

  @impl true
  def run(_params, _context), do: {:ok, %{items: [%{value: 1}, %{value: 2}]}}
end

defmodule JidoTest.ExecFixtures.ShortListOutputAction do
  @moduledoc false
  use Jido.Action, name: "short_list_output_action"

  @impl true
  def run(_params, _context), do: {:ok, %{items: [%{value: 1}]}}
end

defmodule JidoTest.ExecFixtures.ImproperListOutputAction do
  @moduledoc false
  use Jido.Action, name: "improper_list_output_action"

  @impl true
  def run(_params, _context) do
    {:ok, Jido.Action.Output.raw(%{items: [%{value: 1} | :tail]})}
  end
end

defmodule JidoTest.ExecFixtures.ChoiceCountedAction do
  @moduledoc false

  def validate_params(%{test_pid: test_pid} = params) do
    send(test_pid, {__MODULE__, :params})
    {:ok, params}
  end

  def validate_output(%{test_pid: test_pid} = output) do
    send(test_pid, {__MODULE__, :output})
    {:ok, output}
  end

  def run(%{test_pid: test_pid} = params, _context) do
    send(test_pid, {__MODULE__, :run})
    {:ok, params}
  end
end

defmodule JidoTest.ExecFixtures.ChoiceEnvelopeTarget do
  @moduledoc false

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}

  def run(%{value: value}, _context) do
    {:ok, Jido.Action.Output.raw(%{value: value}, meta: %{source: :test})}
  end
end

defmodule JidoTest.ExecFixtures.ChoicePublicEnvelopeAction do
  @moduledoc false

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}

  def run(%{value: value}, _context) do
    {:ok, Jido.Action.Output.raw(%{value: value}, meta: %{source: :nested})}
  end
end

defmodule JidoTest.ExecFixtures.PreflightRecorder do
  @moduledoc false

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}

  def run(%{test_pid: test_pid} = params, _context) do
    send(test_pid, {__MODULE__, :run})
    {:ok, params}
  end
end

defmodule JidoTest.ExecFixtures.UnselectedTarget do
  @moduledoc false

  def validate_params(%{test_pid: test_pid} = params) do
    send(test_pid, {__MODULE__, :params})
    {:ok, params}
  end

  def validate_output(%{test_pid: test_pid} = output) do
    send(test_pid, {__MODULE__, :output})
    {:ok, output}
  end

  def run(%{test_pid: test_pid} = params, _context) do
    send(test_pid, {__MODULE__, :run})
    {:ok, params}
  end
end

defmodule JidoTest.ExecFixtures.ConcurrencyProbeAction do
  @moduledoc false

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}

  def run(%{probe: probe, side: side, test_pid: test_pid}, _context) do
    Agent.update(probe, fn %{max: max, running: running} = state ->
      running = running + 1
      %{state | max: Kernel.max(max, running), running: running}
    end)

    send(test_pid, {__MODULE__, :started, probe, side, self()})

    result =
      receive do
        {:release, ^probe} -> {:ok, %{side: side}}
      after
        4_000 -> {:error, "concurrency probe was not released"}
      end

    Agent.update(probe, &Map.update!(&1, :running, fn running -> running - 1 end))
    result
  end
end

defmodule JidoTest.ExecFixtures.ControlledErrorAction do
  @moduledoc false

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}

  def run(%{message: message} = params, _context) do
    maybe_notify_start(params)
    maybe_block(params)
    {:error, message}
  end

  defp maybe_notify_start(%{key: key, test_pid: test_pid}) do
    send(test_pid, {__MODULE__, :started, key, self()})
  end

  defp maybe_notify_start(_params), do: :ok

  defp maybe_block(%{block: true, key: key}) do
    receive do
      {:release, ^key} -> :ok
    end
  end

  defp maybe_block(_params), do: :ok
end
