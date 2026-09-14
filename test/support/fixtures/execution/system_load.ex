defmodule JidoActionTest.Fixtures.Execution.SystemLoad do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}
  alias Jido.Flow.Map, as: FlowMap

  defmodule HeldWork do
    use Jido.Action, name: "system_load_held_work"

    @impl true
    def run(%{id: id, value: value}, %{observer: observer, run_ref: ref, ledger: ledger}) do
      Agent.update(ledger, fn state ->
        active = state.active + 1
        %{state | active: active, peak: max(state.peak, active), started: [id | state.started]}
      end)

      send(observer, {ref, :ready, id, self()})

      receive do
        {^ref, :release} ->
          Agent.update(ledger, fn state ->
            %{state | active: state.active - 1, completed: [id | state.completed]}
          end)

          {:ok, %{id: id, value: value}}

        {^ref, :fail} ->
          Agent.update(ledger, fn state -> %{state | active: state.active - 1} end)
          {:error, Jido.Action.Error.execution_error("injected held-work failure", %{id: id})}
      end
    end
  end

  defmodule CountedWork do
    use Jido.Action, name: "system_load_counted_work"

    @impl true
    def run(%{id: id, value: value}, %{ledger: ledger, run_ref: ref, observer: observer}) do
      Agent.update(ledger, fn state ->
        %{state | started: [{ref, id} | state.started], completed: [{ref, id} | state.completed]}
      end)

      send(observer, {ref, :worker_done, id, self()})
      {:ok, %{id: id, value: value}}
    end
  end

  def initial_ledger, do: %{active: 0, peak: 0, started: [], completed: []}

  def snapshot(ledger), do: Agent.get(ledger, & &1)

  def composed_flow do
    Flow.new!(
      name: "system_composed_flow",
      components: [
        Step.new!(
          name: "left",
          action: HeldWork,
          params: %{id: :left, value: Ref.input(:left)}
        ),
        Step.new!(
          name: "right",
          action: HeldWork,
          params: %{id: :right, value: Ref.input(:right)}
        ),
        FlowMap.new!(
          name: "mapped",
          action: HeldWork,
          collection: Ref.input(:items),
          params: %{id: Ref.item(), value: Ref.item()},
          needs: ["left", "right"]
        )
      ],
      output: %{
        left: Ref.result("left", :value),
        right: Ref.result("right", :value),
        mapped: Ref.result("mapped")
      }
    )
  end

  def wide_flow(count) do
    Flow.new!(
      name: "load_wide_flow",
      components:
        for id <- 1..count do
          Step.new!(name: "work_#{id}", action: HeldWork, params: %{id: id, value: id})
        end,
      output: %{values: for(id <- 1..count, do: Ref.result("work_#{id}", :value))}
    )
  end

  def map_flow do
    Flow.new!(
      name: "load_map_flow",
      components: [
        FlowMap.new!(
          name: "mapped",
          collection: Ref.input(:items),
          action: HeldWork,
          params: %{id: Ref.item(), value: Ref.item()}
        )
      ],
      output: %{mapped: Ref.result("mapped")}
    )
  end

  def counted_flow do
    Flow.new!(
      name: "load_counted_flow",
      components: [
        Step.new!(
          name: "first",
          action: CountedWork,
          params: %{id: :first, value: Ref.input(:value)}
        ),
        Step.new!(
          name: "second",
          action: CountedWork,
          params: %{id: :second, value: Ref.result("first", :value)}
        )
      ],
      output: %{value: Ref.result("second", :value)}
    )
  end
end
