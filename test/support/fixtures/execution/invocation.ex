defmodule JidoActionTest.Fixtures.Execution.InvocationHost do
  @moduledoc false

  @behaviour Jido.Exec.Invocation

  def start_link do
    Agent.start_link(fn -> %{} end)
  end

  def config(store, owner, opts \\ []) do
    %{
      host: __MODULE__,
      ref: %{
        store: store,
        owner: owner,
        mode: Keyword.get(opts, :mode, :record),
        gate_after: Keyword.get(opts, :gate_after, false)
      },
      run_key: Keyword.get(opts, :run_key, "test-run"),
      compatibility: Keyword.get(opts, :compatibility, :current)
    }
  end

  def receipts(store), do: Agent.get(store, & &1)

  @impl true
  def before_invoke(invocation, ref) do
    send(ref.owner, {:before_invoke, invocation, self()})

    case {ref.mode, Agent.get(ref.store, &Map.get(&1, invocation.id))} do
      {:replay, receipt} when not is_nil(receipt) -> {:replay, receipt}
      _other -> :execute
    end
  end

  @impl true
  def after_invoke(receipt, ref) do
    send(ref.owner, {:after_invoke, receipt, self()})

    if ref.gate_after do
      receive do
        {:accept_receipt, id} when id == receipt.invocation.id -> :ok
      end
    end

    Agent.update(ref.store, &Map.put(&1, receipt.invocation.id, receipt))
    :ok
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationProbe do
  @moduledoc false

  @behaviour Jido.Action
  @behaviour Jido.Executable

  alias Jido.Action.Error
  alias Jido.Action.Output

  @impl true
  def __jido_executable__, do: Jido.Executable.action(__MODULE__)

  @impl true
  def validate_params(params) do
    notify(params, :input)

    case params[:mode] do
      :input_error -> {:error, Error.validation_error("input rejected")}
      _other -> {:ok, Map.put(params, :validated, true)}
    end
  end

  @impl true
  def run(%{validated: true} = params, context) do
    notify(params, {:execution, Map.get(context, :attempt)})

    case params[:mode] do
      :execution_error ->
        {:error, Error.execution_error("execution rejected")}

      :output_error ->
        {:ok, Map.put(params, :invalid_output, true)}

      :envelope ->
        {:ok, Output.raw(params.value), params[:effects] || []}

      :continue ->
        {:continue, Map.take(params, [:observer, :value]), params.target}

      _other ->
        {:ok, %{value: params.value, observer: params[:observer]}, params[:effects] || []}
    end
  end

  @impl true
  def validate_output(%{invalid_output: true} = output) do
    notify(output, :output)
    {:error, Error.validation_error("output rejected")}
  end

  def validate_output(output) do
    notify(output, :output)
    {:ok, Map.delete(output, :observer)}
  end

  defp notify(%{observer: observer}, event) when is_pid(observer) do
    send(observer, {:action_phase, event, self()})
  end

  defp notify(_params, _event), do: :ok
end

defmodule JidoActionTest.Fixtures.Execution.InvocationFinal do
  @moduledoc false

  use Jido.Action, name: "invocation_final"

  @impl true
  def run(params, context) do
    if observer = params[:observer], do: send(observer, {:final_action, context, self()})
    {:ok, Map.take(params, [:value])}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationChanged do
  @moduledoc false

  use Jido.Action, name: "invocation_changed"

  @impl true
  def run(params, context) do
    if observer = context[:observer], do: send(observer, {:changed_action_ran, self()})
    {:ok, Map.put(params, :changed, true)}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationCountedFlow do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias JidoActionTest.Fixtures.Execution.InvocationProbe

  def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

  def flow do
    if counter = Process.whereis(__MODULE__), do: Agent.update(counter, &(&1 + 1))

    Flow.new!(
      name: "invocation_counted_flow",
      components: [
        Step.new!(
          name: "work",
          action: InvocationProbe,
          params: %{observer: Ref.context(:observer), value: Ref.input(:value)}
        )
      ],
      output: Ref.result("work")
    )
  end

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
  def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
end

defmodule JidoActionTest.Fixtures.Execution.InvocationChildFlow do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Jido.Flow.Step
  alias JidoActionTest.Fixtures.Execution.InvocationProbe

  def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

  def flow do
    Flow.new!(
      name: "invocation_child",
      components: [Step.new!(name: "inside", action: InvocationProbe, params: %{value: 1})],
      output: Ref.result("inside")
    )
  end

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
  def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
end

defmodule JidoActionTest.Fixtures.Execution.InvocationInvalidFlow do
  @moduledoc false

  def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
  def flow, do: :not_a_flow
  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
  def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
end
