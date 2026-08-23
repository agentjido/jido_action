defmodule JidoTest.TestActions.KillingAction do
  @moduledoc false
  use Jido.Action, name: "killing_action"

  def run(_params, _context), do: Process.exit(self(), :kill)
end

defmodule JidoTest.TestActions.MapProbeAction do
  @moduledoc false
  use Jido.Action, name: "map_probe_action"

  def run(%{test_pid: test_pid, index: index} = params, _context) when is_pid(test_pid) do
    send(test_pid, {__MODULE__, :started, index, self()})

    if Map.get(params, :block, false) do
      receive do
        :release -> :ok
      end
    end

    case Map.get(params, :outcome, :ok) do
      :ok ->
        output = %{index: index, value: Map.get(params, :value)}

        if Map.get(params, :extras, false) do
          {:ok, output, %{ignored: true}}
        else
          {:ok, output}
        end

      {:error, message} ->
        {:error, message}

      :kill ->
        Process.exit(self(), :kill)
    end
  end
end

defmodule JidoTest.TestActions.CountedMapAction do
  @moduledoc false

  def validate_params(%{test_pid: test_pid, index: index} = params) do
    send(test_pid, {__MODULE__, :input, index})
    {:ok, params}
  end

  def run(%{test_pid: test_pid, index: index} = params, _context) do
    send(test_pid, {__MODULE__, :run, index})
    {:ok, params}
  end

  def validate_output(%{test_pid: test_pid, index: index} = output) do
    send(test_pid, {__MODULE__, :output, index})
    {:ok, output}
  end
end

defmodule JidoTest.TestActions.ReduceProbeAction do
  @moduledoc false
  use Jido.Action, name: "reduce_probe_action"

  def run(
        %{
          accumulator: accumulator,
          item: item,
          index: index,
          item_id: item_id
        } = params,
        context
      ) do
    if test_pid = Map.get(context, :test_pid) do
      send(test_pid, {__MODULE__, :called, index, item_id, item, accumulator})
    end

    case Map.get(params, :outcome, :map) do
      :map ->
        values = Map.get(accumulator, :values, [])

        {:ok, %{values: values ++ [item], indexes: Map.get(accumulator, :indexes, []) ++ [index]}}

      :subtract ->
        {:ok, %{value: Map.fetch!(accumulator, :value) - item}}

      :output ->
        values = accumulator.value.values
        {:ok, Jido.Action.Output.raw(%{values: values ++ [item]}, meta: %{source: :reduce})}

      :scalar ->
        {:ok, :invalid_reduce_output}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule JidoTest.TestActions.RecorderAction do
  @moduledoc false
  use Jido.Action, name: "recorder_action"

  def run(params, %{test_pid: test_pid}) when is_pid(test_pid) do
    send(test_pid, {__MODULE__, params})
    {:ok, params}
  end

  def run(params, _context), do: {:ok, params}
end
