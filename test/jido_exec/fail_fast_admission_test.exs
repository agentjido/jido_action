defmodule JidoActionTest.Exec.FailFastAdmissionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step}

  defmodule ControlledAction do
    use Jido.Action, name: "fail_fast_controlled"

    @impl true
    def run(params, %{owner: owner, gate: gate, ref: ref, blocked: blocked}) do
      position = Agent.get_and_update(gate, fn count -> {count, count + 1} end)
      send(owner, {ref, :started, position, params.id, self()})

      if position < blocked do
        receive do
          :fail -> {:error, Jido.Action.Error.execution_error("selected failure")}
          :kill -> Process.exit(self(), :kill)
          :finish -> {:ok, params}
        end
      else
        {:ok, params}
      end
    end
  end

  test "serial wave and continue stop after the first admitted failure" do
    for operation <- [:wave, :continue] do
      {context, ref} = context(1)
      assert {:ok, execution} = Exec.start(flow(), %{}, context, max_concurrency: 1)
      [first | _] = Exec.ready(execution)
      task = Task.async(fn -> apply(Exec, operation, [execution]) end)

      try do
        assert_receive {^ref, :started, 0, _id, worker}, 1_000
        send(worker, :fail)
        result = Task.await(task)

        completed =
          case result do
            {:ok, [runnable], completed} ->
              assert runnable == %{first | status: :failed}
              completed

            {:ok, completed} ->
              completed
          end

        assert {:error, %{message: "selected failure"}} = Exec.result(completed)
        refute_received {^ref, :started, _, _, _}
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "a later concurrent failure stops admission while the first runnable is blocked" do
    {context, ref} = context(2)
    owner = self()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :flow, :node, :start],
        &__MODULE__.track_runnable/4,
        {owner, ref}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, execution} = Exec.start(flow(), %{}, context, max_concurrency: 2)
    ready = Exec.ready(execution)
    ready_names = Enum.map(ready, &hd(&1.component_path))
    task = Task.async(fn -> Exec.wave(execution) end)

    try do
      first_name = hd(ready_names)
      second_name = Enum.at(ready_names, 1)
      assert_receive {^ref, :runnable, ^first_name, _first_runnable}, 1_000
      assert_receive {^ref, :runnable, ^second_name, second_runnable}, 1_000
      assert_receive {^ref, :started, _, ^first_name, first_worker}, 1_000
      assert_receive {^ref, :started, _, ^second_name, second_worker}, 1_000
      monitor = Process.monitor(second_runnable)
      send(second_worker, :fail)
      assert_receive {:DOWN, ^monitor, :process, ^second_runnable, :normal}, 1_000
      assert Process.alive?(first_worker)
      send(first_worker, :finish)

      assert {:ok, applied, completed} = Task.await(task)
      assert Enum.map(applied, &hd(&1.component_path)) == [first_name, second_name]
      assert Enum.map(applied, & &1.status) == [:completed, :failed]
      assert Enum.map(applied, & &1.token) == Enum.map(Enum.take(ready, 2), & &1.token)
      assert {:error, %{message: "selected failure"}} = Exec.result(completed)
      refute_received {^ref, :started, _, _, _}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "a killed native worker stops admission for a caller that traps exits" do
    {context, ref} = context(0)
    assert {:ok, execution} = Exec.start(flow(), %{}, context, max_concurrency: 2)
    ready = Exec.ready(execution)
    [first, second | _] = Enum.map(ready, &hd(&1.component_path))
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :flow, :node, :start],
        &__MODULE__.gate_native_runnable/4,
        {self(), ref, execution.id, [first, second]}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        Exec.wave(execution)
      end)

    try do
      assert_receive {^ref, :native, ^first, first_worker}, 1_000
      assert_receive {^ref, :native, ^second, second_worker}, 1_000
      monitor = Process.monitor(second_worker)
      Process.exit(second_worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^second_worker, :killed}, 1_000
      send(first_worker, :release)

      assert {:ok, applied, completed} = Task.await(task)
      assert Enum.map(applied, &hd(&1.component_path)) == [first, second]
      assert Enum.map(applied, & &1.status) == [:completed, :failed]
      assert Enum.map(applied, & &1.token) == Enum.map(Enum.take(ready, 2), & &1.token)
      assert {:error, %{message: "flow runnable task exited"}} = Exec.result(completed)
      refute_received {^ref, :native, _, _}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  @doc false
  def gate_native_runnable(_event, _measurements, metadata, {owner, ref, execution_id, names}) do
    if metadata.execution_id == execution_id do
      send(owner, {ref, :native, metadata.node, self()})

      if metadata.node in names do
        receive do
          :release -> :ok
        end
      end
    end
  end

  test "Map fail-fast stops admission through synchronous and asynchronous runs" do
    for mode <- [:run, :async], concurrency <- [1, 2], failure <- [:fail, :kill] do
      {context, ref} = context(concurrency)
      owner = self()

      task =
        Task.async(fn ->
          result =
            if mode == :run do
              Exec.run(map_flow(:fail_fast), %{}, context, max_concurrency: concurrency)
            else
              handle =
                Exec.run_async(map_flow(:fail_fast), %{}, context, max_concurrency: concurrency)

              Exec.await(handle)
            end

          send(owner, {ref, :complete})
          result
        end)

      try do
        workers =
          for _ <- 1..concurrency do
            assert_receive {^ref, :started, position, _id, worker}, 1_000
            {position, worker}
          end

        Enum.each(workers, fn {_, worker} -> send(worker, failure) end)
        assert {:error, _} = Task.await(task)
        assert_received {^ref, :complete}
        refute_received {^ref, :started, _, _, _}
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "cancellation stops admitted workers without starting pending work" do
    {context, ref} = context(2)
    handle = Exec.run_async(flow(), %{}, context, max_concurrency: 2)

    try do
      monitors =
        for _ <- 1..2 do
          assert_receive {^ref, :started, _, _id, worker}, 1_000
          {worker, Process.monitor(worker)}
        end

      assert :ok = Exec.cancel(handle)

      for {worker, monitor} <- monitors do
        assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      end

      refute_received {^ref, :started, _, _, _}
    after
      Exec.cancel(handle)
    end
  end

  @doc false
  def track_runnable(_event, _measurements, metadata, {owner, ref}) do
    if metadata.flow == "fail_fast_admission" do
      send(owner, {ref, :runnable, metadata.node, self()})
    end
  end

  test "Map collected errors do not stop admission" do
    {context, ref} = context(1)

    task =
      Task.async(fn -> Exec.run(map_flow(:collect_errors), %{}, context, max_concurrency: 1) end)

    try do
      assert_receive {^ref, :started, 0, failed_id, worker}, 1_000
      send(worker, :fail)
      assert {:ok, %{items: items}} = Task.await(task)
      assert length(items) == 5
      assert Enum.at(items, failed_id - 1).status == :error

      for _ <- 1..4 do
        assert_received {^ref, :started, _, _, _}
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp context(blocked) do
    gate = start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    ref = make_ref()
    {%{owner: self(), gate: gate, ref: ref, blocked: blocked}, ref}
  end

  defp flow do
    names = Enum.map(1..5, &"step_#{&1}")

    Flow.new!(
      name: "fail_fast_admission",
      components:
        Enum.map(names, &Step.new!(name: &1, action: ControlledAction, params: %{id: &1})),
      output: Map.new(names, &{&1, Ref.result(&1)})
    )
  end

  defp map_flow(mode) do
    Flow.new!(
      name: "fail_fast_map",
      components: [
        Jido.Flow.Map.new!(
          name: "items",
          collection: Enum.to_list(1..5),
          action: ControlledAction,
          params: %{id: Ref.item()},
          on_error: mode
        )
      ],
      output: %{items: Ref.result("items")}
    )
  end
end
