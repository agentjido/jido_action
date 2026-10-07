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
      {:replay, receipt} when not is_nil(receipt) ->
        {:replay, receipt}

      {:reject_existing, receipt} when not is_nil(receipt) ->
        {:interrupt, :compatibility_rejected}

      _other ->
        :execute
    end
  end

  @impl true
  def after_invoke(receipt, ref) do
    send(ref.owner, {:after_invoke, receipt, self()})

    result =
      if ref.gate_after do
        receive do
          {:accept_receipt, id} when id == receipt.invocation.id -> :ok
          {:reject_receipt, id, reason} when id == receipt.invocation.id -> {:interrupt, reason}
        end
      else
        :ok
      end

    case result do
      :ok -> Agent.update(ref.store, &Map.put(&1, receipt.invocation.id, receipt))
      other -> other
    end
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationFold do
  @moduledoc false

  use Jido.Action, name: "invocation_fold"

  @impl true
  def run(%{accumulator: %{values: values}, index: index, item: item} = params, _context) do
    if observer = params[:observer], do: send(observer, {:fold_body, index, values, self()})
    {:ok, %{values: values ++ [item]}, [{:fold_effect, index}]}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationLoop do
  @moduledoc false

  @behaviour Jido.Action

  @impl true
  def validate_params(params) do
    notify(params, :input)
    {:ok, params}
  end

  @impl true
  def run(%{index: index, state: %{count: count}} = params, _context) do
    notify(params, :execution)
    {:ok, %{count: count + 1, index: index, observer: params[:observer]}, [{:loop_effect, index}]}
  end

  @impl true
  def validate_output(output) do
    notify(output, :output)
    {:ok, Map.delete(output, :observer)}
  end

  def state_transform(value, _opts) do
    record({:loop_state_transform, value})
    {:ok, value}
  end

  def record(event) do
    if recorder = Process.whereis(__MODULE__), do: Agent.update(recorder, &[event | &1])
    :ok
  end

  defp notify(%{observer: observer, index: index}, phase) when is_pid(observer) do
    send(observer, {:loop_action, phase, index, self()})
  end

  defp notify(_value, _phase), do: :ok
end

defmodule JidoActionTest.Fixtures.Execution.InvocationDispatchDecision do
  @moduledoc false

  use Jido.Action, name: "invocation_dispatch_decision"

  @impl true
  def run(params, context) do
    if observer = context[:observer], do: send(observer, {:dispatch_body, :decision, self()})
    {:ok, params, [:decision_effect]}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationDispatchExpander do
  @moduledoc false

  use Jido.Action, name: "invocation_dispatch_expander"

  @impl true
  def run(%{continue?: true} = params, context) do
    if observer = context[:observer], do: send(observer, {:dispatch_body, :expander, self()})

    {:continue, Map.take(params, [:value]), JidoActionTest.Fixtures.Execution.InvocationFinal}
  end

  def run(params, context) do
    if observer = context[:observer], do: send(observer, {:dispatch_body, :expander, self()})
    {:ok, Map.take(params, [:value]), [:expander_effect]}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationLazyOutput do
  @moduledoc false

  use Jido.Action, name: "invocation_lazy_output"

  alias Jido.Action.Output

  @impl true
  def run(%{observer: observer}, _context) do
    stream =
      Stream.map([1], fn value ->
        send(observer, {:lazy_value, value})
        value
      end)

    {:ok, Output.stream(stream)}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationRestartAction do
  @moduledoc false

  use Jido.Action, name: "invocation_restart_action"

  @impl true
  def run(%{index: index, value: value}, context) do
    Agent.update(context.recorder, &[{context.attempt, index} | &1])
    {:ok, %{index: index, value: value}, [{:restart_effect, index}]}
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationRestart do
  @moduledoc false

  alias Jido.Exec
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Execution.InvocationHost
  alias JidoActionTest.Fixtures.Execution.InvocationRestartAction

  def definition do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_restart",
      components: [
        JidoActionTest.FlowComponent.map!(
          name: "items",
          collection: Ref.input(:items),
          action: InvocationRestartAction,
          params: %{index: Ref.item_index(), value: Ref.item()}
        )
      ],
      output: %{items: Ref.result("items")}
    )
  end

  def call_data, do: %{items: [:same, :same, :same]}

  def run_first do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    result =
      Exec.run(definition(), call_data(), %{attempt: :vm_one, recorder: recorder},
        max_concurrency: 2,
        invocation: InvocationHost.config(store, self(), run_key: "fresh-vm")
      )

    receipts = InvocationHost.receipts(store)

    kept =
      receipts
      |> Enum.reject(fn {id, _receipt} -> id.selector == %{index: 1} end)
      |> Map.new()

    %{
      definition: definition(),
      call_data: call_data(),
      receipts: kept,
      result: result,
      executed: recorder |> Agent.get(&Enum.reverse/1)
    }
  end

  def run_second(%{definition: definition, call_data: call_data, receipts: receipts}) do
    {:ok, store} = Agent.start_link(fn -> receipts end)
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    result =
      Exec.run(definition, call_data, %{attempt: :vm_two, recorder: recorder},
        max_concurrency: 1,
        invocation: InvocationHost.config(store, self(), mode: :replay, run_key: "fresh-vm")
      )

    %{
      result: result,
      executed: recorder |> Agent.get(&Enum.reverse/1),
      receipt_count: store |> InvocationHost.receipts() |> map_size()
    }
  end
end

defmodule JidoActionTest.Fixtures.Execution.InvocationProbe do
  @moduledoc false

  @behaviour Jido.Action

  alias Jido.Action.Error
  alias Jido.Action.Output

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

  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Execution.InvocationProbe

  @behaviour Jido.Flow

  def flow do
    if counter = Process.whereis(__MODULE__), do: Agent.update(counter, &(&1 + 1))

    JidoActionTest.FlowBuilder.new!(
      name: "invocation_counted_flow",
      components: [
        JidoActionTest.FlowComponent.step!(
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

  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Execution.InvocationProbe

  @behaviour Jido.Flow

  def flow do
    JidoActionTest.FlowBuilder.new!(
      name: "invocation_child",
      components: [
        JidoActionTest.FlowComponent.step!(
          name: "inside",
          action: InvocationProbe,
          params: %{value: 1}
        )
      ],
      output: Ref.result("inside")
    )
  end

  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
  def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
end

defmodule JidoActionTest.Fixtures.Execution.InvocationInvalidFlow do
  @moduledoc false

  @behaviour Jido.Flow
  def flow, do: :not_a_flow
  def validate_params(params), do: {:ok, params}
  def validate_output(output), do: {:ok, output}
  def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
end
