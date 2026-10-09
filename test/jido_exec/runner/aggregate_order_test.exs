defmodule Jido.Exec.Runner.AggregateOrderTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Flow.Ref
  alias Runic.Runner
  alias Runic.Workflow

  defmodule Echo do
    use Jido.Action, name: "aggregate_order_echo"
    @impl true
    def run(params, _), do: {:ok, params}
  end

  defmodule Fail do
    use Jido.Action, name: "aggregate_order_fail"
    @impl true
    def run(%{label: label}, _), do: {:error, label}
  end

  defmodule GatedExecutor do
    @behaviour Runic.Runner.Executor
    alias Runic.Runner.Executor.Task, as: Native
    @impl true
    def init(opts) do
      {:ok, native} = Native.init(opts)
      {:ok, {native, Keyword.fetch!(opts, :observer)}}
    end

    @impl true
    def dispatch(work, opts, {native, owner}) do
      {handle, next} =
        Native.dispatch(
          fn ->
            result = work.()

            ready =
              case result do
                {runnable, _events} -> runnable
                runnable -> runnable
              end

            if aggregate?(ready.node) do
              send(owner, {:aggregate_ready, ready.node.hash, ready.id, self()})
              receive do: (:release -> :ok)
            end

            result
          end,
          opts,
          native
        )

      {handle, {next, owner}}
    end

    @impl true
    def release(handle, {native, owner}), do: {Native.release(handle, native), owner}
    @impl true
    def cleanup({native, _}), do: Native.cleanup(native)
    def aggregate?(node), do: is_struct(node, Workflow.Join) or is_struct(node, Workflow.FanIn)
  end

  setup do
    runner = :"aggregate_order_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for boundary <- [:join, :fan_in] do
    test "#{boundary} completion order preserves identities and serial failure selection", %{
      runner: runner
    } do
      boundary = unquote(boundary)
      flow = flow(boundary)
      params = %{items: [1, 2]}
      {:error, serial} = Exec.run(flow, params)
      forward = managed(runner, flow, params, boundary, :forward)
      reverse = managed(runner, flow, params, boundary, :reverse)
      assert aggregate_ids(reverse) == aggregate_ids(forward)

      for completed <- [forward, reverse] do
        assert {:error, error} = Exec.result(completed)
        assert Exception.message(error) == Exception.message(serial)
      end
    end
  end

  defp managed(runner, flow, params, boundary, direction) do
    owner = self()
    id = {boundary, direction}

    {:ok, _} =
      Exec.start(runner, id, flow, params, %{},
        max_concurrency: 4,
        executor: GatedExecutor,
        executor_opts: [observer: owner],
        hooks: [
          on_complete: fn runnable, _, _ ->
            if GatedExecutor.aggregate?(runnable.node),
              do: send(owner, {:aggregate_accepted, runnable.id})
          end
        ],
        on_complete: fn _, wf -> send(owner, {:done, wf}) end
      )

    count = if boundary == :join, do: 2, else: 4

    arrivals =
      for _ <- 1..count do
        assert_receive {:aggregate_ready, hash, key, pid}, 2000
        {hash, key, pid}
      end

    pairs =
      arrivals
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {_, group} ->
        pair = Enum.sort_by(group, &elem(&1, 1))
        if direction == :forward, do: pair, else: Enum.reverse(pair)
      end)

    firsts = Enum.map(pairs, &hd/1)
    for {_, _, pid} <- firsts, do: send(pid, :release)

    for {_, key, _} <- firsts do
      assert_receive {:aggregate_accepted, ^key}, 2000
    end

    # The call confirms that accepted completion handlers have finished.
    assert {:ok, _} = Runner.admission_status(runner, id)
    for [_, {_, _, pid}] <- pairs, do: send(pid, :release)
    assert_receive {:done, workflow}, 2000
    assert :ok = Runner.stop(runner, id, persist: false)
    workflow
  end

  defp aggregate_ids(workflow) do
    hashes =
      workflow.graph.vertices
      |> Enum.flat_map(fn {_, node} ->
        if GatedExecutor.aggregate?(node), do: [node.hash], else: []
      end)
      |> MapSet.new()

    Workflow.facts(workflow)
    |> Enum.flat_map(fn fact ->
      case fact.ancestry do
        {producer, _} -> if MapSet.member?(hashes, producer), do: [fact.hash], else: []
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp flow(boundary) do
    parents =
      case boundary do
        :join ->
          for name <- ["pa", "pb"],
              do: %{kind: :step, name: name, action: Echo, params: %{value: name}}

        :fan_in ->
          for name <- ["pa", "pb"],
              do: %{
                kind: :map,
                name: name,
                collection: Ref.input(:items),
                action: Echo,
                params: %{value: Ref.item()}
              }
      end

    Jido.Flow.new!(%{
      name: "aggregate_order_#{boundary}",
      components:
        parents ++
          [
            %{
              kind: :step,
              name: "fa",
              action: Fail,
              params: %{label: "a"},
              needs: if(boundary == :join, do: ["pa", "pb"], else: ["pa"])
            },
            %{
              kind: :step,
              name: "fb",
              action: Fail,
              params: %{label: "b"},
              needs: if(boundary == :join, do: ["pa", "pb"], else: ["pb"])
            }
          ],
      output: %{a: Ref.result("fa"), b: Ref.result("fb")}
    })
  end
end
