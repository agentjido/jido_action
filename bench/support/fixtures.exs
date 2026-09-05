defmodule JidoActionBench.Echo do
  @moduledoc false
  use Jido.Action, name: "benchmark_echo"

  @impl true
  def run(params, context) do
    JidoActionBench.Fixtures.barrier(context)
    {:ok, params}
  end
end

defmodule JidoActionBench.Child do
  @moduledoc false
  use Jido.Flow, name: "benchmark_child"

  flow do
    step "echo", action: JidoActionBench.Echo, params: %{value: input(:value)}
    output result("echo")
  end
end

defmodule JidoActionBench.Fixtures do
  @moduledoc false
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step, Subflow}
  alias JidoActionBench.Echo

  def barrier(context) do
    if observer = context[:bench_observer] do
      ref = make_ref()
      send(observer, {:bench_barrier, self(), ref})

      receive do
        {:bench_release, ^ref} -> :ok
      after
        30_000 -> raise "benchmark barrier was not released"
      end
    end
  end

  def workloads(count, payload) when count in 1..32 do
    input = %{value: payload(payload)}
    action_workloads(input) ++ flow_workloads(count, input)
  end

  def workloads(_count, _payload), do: raise(ArgumentError, "graph size must be in 1..32")

  def graph(shape, count) when count in 1..32 do
    components =
      for index <- 1..count do
        name = "s#{index}"

        value =
          if shape == :serial and index > 1,
            do: Ref.result("s#{index - 1}", :value),
            else: Ref.input(:value)

        if shape == :subflows do
          Subflow.new!(name: name, flow: JidoActionBench.Child, params: %{value: value})
        else
          Step.new!(name: name, action: Echo, params: %{value: value})
        end
      end

    output = Map.new(1..count, &{"s#{&1}", Ref.result("s#{&1}")})
    Flow.new!(name: "benchmark_#{shape}", components: components, output: output)
  end

  defp payload(:small), do: 42
  defp payload(:large_map), do: Map.new(1..1_000, &{&1, &1 * 2})
  defp payload(:large_binary), do: :binary.copy(<<42>>, 1_048_576)

  defp action_workloads(input) do
    for mode <- [:direct, :run, :finite_timeout, :async_await] do
      %{
        name: "action/#{mode}",
        setup: fn context -> context end,
        run: fn context -> action(mode, input, context) end,
        check: &expect!(&1, {:ok, input}),
        retained: input
      }
    end
  end

  defp action(:direct, input, context), do: Echo.run(input, context)

  defp action(:run, input, context),
    do: Exec.run(Echo, input, context, task_supervisor: JidoActionBench.TaskSupervisor)

  defp action(:finite_timeout, input, context),
    do:
      Exec.run(Echo, input, context,
        task_supervisor: JidoActionBench.TaskSupervisor,
        timeout: 30_000
      )

  defp action(:async_await, input, context) do
    Echo
    |> Exec.run_async(input, context, task_supervisor: JidoActionBench.TaskSupervisor)
    |> Exec.await(30_000)
  end

  defp flow_workloads(count, input) do
    for shape <- [:serial, :parallel, :subflows],
        workload <- flow_cases(graph(shape, count), input, count, shape),
        do: workload
  end

  defp flow_cases(flow, input, count, shape) do
    {:ok, compiled} = Flow.compile(flow)
    expected = {:ok, Map.new(1..count, &{"s#{&1}", input})}

    opts = [
      task_supervisor: JidoActionBench.TaskSupervisor,
      max_concurrency: if(shape == :serial, do: 1, else: 4)
    ]

    common = %{setup: fn context -> context end, retained: {flow, compiled, input}}

    [
      Map.merge(common, %{
        name: "#{shape}/validate",
        run: fn _ -> Flow.validate_executable(flow) end,
        check: &expect!(&1, {:ok, flow})
      }),
      Map.merge(common, %{
        name: "#{shape}/compile",
        run: fn _ -> Flow.compile(flow) end,
        check: fn {:ok, result} ->
          expect!(result.compilation_digest, compiled.compilation_digest)
        end
      }),
      Map.merge(common, %{
        name: "#{shape}/run",
        run: fn context -> Exec.run(flow, input, context, opts) end,
        check: &expect!(&1, expected)
      }),
      Map.merge(common, %{
        name: "#{shape}/prepared_reuse",
        run: fn context -> run_prepared(flow, compiled, input, context, opts) end,
        check: &expect!(&1, expected)
      }),
      %{
        name: "#{shape}/paused_continue",
        setup: fn context ->
          {:ok, execution} = Exec.start(flow, input, context, opts)
          [_ | _] = Exec.ready(execution)
          barrier(context)
          execution
        end,
        run: fn execution ->
          {:ok, finished} = Exec.continue(execution)
          Exec.result(finished)
        end,
        check: &expect!(&1, expected),
        retained: {flow, compiled, input}
      }
    ]
  end

  # Internal measurement adapter for these empty-schema fixtures only. There is
  # no public compiled-graph run API. Each call gets fresh execution state.
  defp run_prepared(flow, compiled, input, context, opts) do
    {:ok, options} = Jido.Exec.Options.validate_flow(opts, :start)
    id = "bench_#{System.unique_integer([:positive])}"
    name = flow.name
    span = Jido.Exec.Telemetry.start([:jido, :flow], %{execution_id: id, flow: name})

    runner = fn target, params, target_context, execution_id, owner ->
      Jido.Exec.Flow.TargetRunner.run(
        target,
        params,
        target_context,
        execution_id,
        options,
        name,
        owner
      )
    end

    {:ok, execution} =
      Jido.Exec.Flow.Engine.start(
        flow,
        compiled,
        input,
        context,
        options,
        &{:ok, &1},
        runner,
        id,
        %{flow: span}
      )

    {:ok, finished} = Exec.continue(execution)
    Exec.result(finished)
  end

  defp expect!(actual, expected) do
    if actual != expected, do: raise("benchmark returned an incorrect result")
    :ok
  end
end
