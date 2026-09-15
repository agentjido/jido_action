defmodule JidoActionLoad.Identity do
  @moduledoc false
  use Jido.Action, name: "load_identity"

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value}}
end

defmodule JidoActionLoad.Throughput do
  @moduledoc false
  require Runic

  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionLoad.Identity
  alias Runic.Workflow

  @phase_calls [
    {Workflow, :plan_eagerly, 2},
    {Workflow, :prepare_for_dispatch, 1},
    {Workflow, :execute_runnable, 1},
    {Workflow, :apply_runnable, 2}
  ]

  def settings("smoke"),
    do: %{
      profile: "smoke",
      sizes: [8, 32],
      partition_items: 32,
      groups: [1, 4],
      graph_width: 4,
      graph_needs: [1, 4],
      reuse_runs: 4,
      warmup: 1,
      samples: 2,
      max_case_process_bytes: 256 * 1_048_576
    }

  def settings("stress"),
    do: %{
      profile: "stress",
      sizes: [128, 512, 2_048, 8_192],
      partition_items: 1_024,
      groups: [1, 16],
      graph_width: 16,
      graph_needs: [1, 4, 16],
      reuse_runs: 250,
      warmup: 1,
      samples: 3,
      max_case_process_bytes: 2_048 * 1_048_576
    }

  def settings("extreme"),
    do: %{
      profile: "extreme",
      sizes: [16_384],
      partition_items: 4_096,
      groups: [1, 64],
      graph_width: 32,
      graph_needs: [1, 8, 32],
      reuse_runs: 1_000,
      warmup: 0,
      samples: 1,
      max_case_process_bytes: 4_096 * 1_048_576
    }

  def settings(_), do: raise(ArgumentError, "profile must be smoke, stress, or extreme")

  def cases(settings) do
    maps =
      for size <- settings.sizes,
          values <- [:unique, :repeated],
          system <- [:runic, :jido] do
        items = items(size, values)

        case system do
          :runic -> native_map_case(items, values)
          :jido -> jido_map_case(items, values)
        end
      end

    partitions =
      for groups <- settings.groups do
        partition_case(settings.partition_items, groups)
      end

    graphs =
      for needs <- settings.graph_needs do
        dependency_case(settings.graph_width, needs)
      end

    maps ++ partitions ++ graphs ++ [reuse_case(settings.reuse_runs)]
  end

  def run(profile, filter \\ nil, opts \\ []) do
    settings =
      case Keyword.fetch(opts, :max_case_process_bytes) do
        {:ok, bytes} when is_integer(bytes) and bytes > 0 ->
          Map.put(settings(profile), :max_case_process_bytes, bytes)

        :error ->
          settings(profile)

        _ ->
          raise ArgumentError, "max_case_process_bytes must be positive"
      end

    on_case = Keyword.get(opts, :on_case, fn _row -> :ok end)
    selected = cases(settings)

    selected =
      if filter, do: Enum.filter(selected, &String.contains?(&1.id, filter)), else: selected

    if selected == [], do: raise(ArgumentError, "no throughput cases match the filter")

    rows =
      Enum.map(selected, fn benchmark ->
        IO.puts("Measuring #{benchmark.id}...")
        row = guarded_measure(benchmark, settings)
        on_case.(row)
        if row.status == "failed", do: raise("throughput case failed: #{row.id}: #{row.reason}")
        row
      end)

    %{
      schema_version: 1,
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source: source(),
      environment: environment(),
      settings: Map.put(settings, :filter, filter),
      method:
        "execution-only timing; separate Runic call-time probe; checked results; per-case process memory guard",
      comparisons: comparisons(rows),
      limitations: [
        "Runic-native and Jido Flow graphs do not have identical work. Their time difference is not exact Jido overhead.",
        "Native Runic Map results are checked as a multiset; Jido Flow Map results are checked in input order.",
        "Runic call-time probes change execution speed. Use untraced timing for throughput comparisons.",
        "Runic call times are caller-process measurements and can overlap. Do not add them as a wall-time breakdown.",
        "Caller reductions omit helper processes. Workflow heap size omits off-heap binaries and is not a peak-memory measure.",
        "The memory guard observes only the case process at intervals. It can miss short peaks and does not measure all VM memory.",
        "Results on a shared host are observations, not speed guarantees. No timing value is a pass condition."
      ],
      cases: rows
    }
  end

  def write!(report, directory) do
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "report.json"), JSON.encode!(report))
    File.write!(Path.join(directory, "report.md"), markdown(report))
  end

  defp guarded_measure(benchmark, settings) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, measure(benchmark, settings)}
          rescue
            error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
          catch
            kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
          end

        send(parent, {:throughput_case, self(), result})
      end)

    try do
      observe_case(pid, monitor, benchmark, settings.max_case_process_bytes, 0)
    after
      # A killed probe cannot run its own `after` clause. Do not leave global
      # call-time patterns active for the next case.
      Enum.each(@phase_calls, &:erlang.trace_pattern(&1, false, [:call_time]))
    end
  end

  defp observe_case(pid, monitor, benchmark, limit, peak) do
    current =
      case Process.info(pid, :memory) do
        {:memory, bytes} -> bytes
        nil -> 0
      end

    peak = max(peak, current)

    if current > limit do
      Process.exit(pid, :kill)
      await_case_down(monitor, pid)
      aborted(benchmark, peak, "case process exceeded #{limit} bytes")
    else
      receive do
        {:throughput_case, ^pid, {:ok, row}} ->
          await_case_down(monitor, pid)
          Map.put(row, :observed_peak_process_bytes, peak)

        {:throughput_case, ^pid, {:error, reason}} ->
          await_case_down(monitor, pid)
          failed(benchmark, peak, reason)

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          failed(benchmark, peak, "case process exited: #{inspect(reason)}")
      after
        100 -> observe_case(pid, monitor, benchmark, limit, peak)
      end
    end
  end

  defp await_case_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      5_000 -> raise("case process did not exit")
    end
  end

  defp aborted(benchmark, peak, reason) do
    %{
      id: benchmark.id,
      kind: benchmark.kind,
      system: benchmark.system,
      status: "aborted",
      items: benchmark.items,
      observed_peak_process_bytes: peak,
      reason: reason
    }
  end

  defp failed(benchmark, peak, reason) do
    benchmark |> aborted(peak, reason) |> Map.put(:status, "failed")
  end

  defp native_map_case(items, values) do
    map = Runic.map(fn item -> item end, name: :native_map)

    reduce =
      Runic.reduce([], fn item, acc -> [item | acc] end,
        name: :native_gather,
        map: :native_map
      )

    workflow = Workflow.new() |> Workflow.add(map) |> Workflow.add(reduce, to: :native_map)
    size = length(items)

    %{
      id: "map/runic/#{values}/#{size}",
      kind: "map",
      system: "runic",
      values: values,
      items: size,
      run: fn -> run_native(workflow, items) end,
      check: fn finished ->
        actual = Workflow.results(finished, [:native_gather]) |> Map.fetch!(:native_gather)
        expect_same_items!(actual, items)
      end,
      workflow: & &1
    }
  end

  defp jido_map_case(items, values) do
    {flow, input, expected} = partition_fixture(items, 1)
    {:ok, compiled} = Flow.compile(flow)
    size = length(items)

    %{
      id: "map/jido/#{values}/#{size}",
      kind: "map",
      system: "jido",
      values: values,
      items: size,
      run: fn -> run_compiled(flow, compiled, input) end,
      check: fn finished -> expect!(Exec.result(finished), {:ok, expected}) end,
      workflow: & &1.workflow
    }
  end

  defp partition_case(total, groups) do
    items = items(total, :unique)
    {flow, input, expected} = partition_fixture(items, groups)
    {:ok, compiled} = Flow.compile(flow)

    %{
      id: "partition/jido/#{total}/#{groups}_maps",
      kind: "partition",
      system: "jido",
      values: :unique,
      groups: groups,
      items: total,
      run: fn -> run_compiled(flow, compiled, input) end,
      check: fn finished -> expect!(Exec.result(finished), {:ok, expected}) end,
      workflow: & &1.workflow
    }
  end

  defp partition_fixture(items, groups) do
    if rem(length(items), groups) != 0, do: raise(ArgumentError, "uneven Map partition")

    chunks = Enum.chunk_every(items, div(length(items), groups))

    named =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, index} -> {"map_#{index}", chunk} end)

    components =
      for {name, _chunk} <- named do
        FlowMap.new!(
          name: name,
          collection: Ref.input([:groups, name]),
          action: Identity,
          params: %{value: Ref.item()}
        )
      end

    flow =
      Flow.new!(
        name: "throughput_partition_#{groups}",
        components: components,
        output: Map.new(named, fn {name, _chunk} -> {name, Ref.result(name)} end)
      )

    input = %{groups: Map.new(named)}

    expected =
      Map.new(named, fn {name, chunk} ->
        {name, Enum.map(chunk, &%{value: &1})}
      end)

    {flow, input, expected}
  end

  defp dependency_case(width, needs) do
    producers =
      for index <- 1..width do
        Step.new!(name: "producer_#{index}", action: Identity, params: %{value: index})
      end

    readers =
      for index <- 1..width do
        sources = for offset <- 0..(needs - 1), do: 1 + rem(index + offset - 1, width)

        params = %{
          value:
            Map.new(sources, fn source ->
              {"p_#{source}", Ref.result("producer_#{source}", :value)}
            end)
        }

        Step.new!(name: "reader_#{index}", action: Identity, params: params)
      end

    flow =
      Flow.new!(
        name: "throughput_dependencies_#{width}_#{needs}",
        components: producers ++ readers,
        output: Map.new(1..width, &{"reader_#{&1}", Ref.result("reader_#{&1}")})
      )

    expected =
      Map.new(1..width, fn index ->
        sources = for offset <- 0..(needs - 1), do: 1 + rem(index + offset - 1, width)
        values = Map.new(sources, &{"p_#{&1}", &1})
        {"reader_#{index}", %{value: values}}
      end)

    {:ok, compiled} = Flow.compile(flow)

    %{
      id: "graph/jido/#{width}_producers_#{width}_readers/#{needs}_needs",
      kind: "graph",
      system: "jido",
      values: :unique,
      width: width,
      needs: needs,
      items: width * 2,
      run: fn -> run_compiled(flow, compiled, %{}) end,
      check: fn finished -> expect!(Exec.result(finished), {:ok, expected}) end,
      workflow: & &1.workflow
    }
  end

  defp reuse_case(runs) do
    items = items(8, :unique)
    {flow, _input, expected} = partition_fixture(items, 1)
    {:ok, compiled} = Flow.compile(flow)

    %{
      id: "reuse/jido/#{runs}_runs",
      kind: "reuse",
      system: "jido",
      values: :changing,
      items: runs * length(items),
      run: fn ->
        {results, last} =
          Enum.map_reduce(1..runs, nil, fn index, _previous ->
            input = %{groups: %{"map_1" => Enum.map(items, &(&1 + index))}}
            finished = run_compiled(flow, compiled, input)
            {Exec.result(finished), finished.workflow}
          end)

        %{results: results, workflow: last}
      end,
      check: fn %{results: results} ->
        for {actual, index} <- Enum.with_index(results, 1) do
          wanted =
            Map.update!(expected, "map_1", fn values ->
              Enum.map(values, &%{value: &1.value + index})
            end)

          expect!(actual, {:ok, wanted})
        end
      end,
      workflow: & &1.workflow
    }
  end

  defp run_native(workflow, items) do
    workflow |> Workflow.plan_eagerly(items) |> run_native_waves()
  end

  defp run_native_waves(workflow) do
    {workflow, ready} = Workflow.prepare_for_dispatch(workflow)

    case ready do
      [] ->
        if Workflow.is_runnable?(workflow), do: raise("native Runic workflow made no progress")
        workflow

      ready ->
        Enum.reduce(ready, workflow, fn runnable, current ->
          Workflow.apply_runnable(current, Workflow.execute_runnable(runnable))
        end)
        |> run_native_waves()
    end
  end

  # Benchmark-only adapter. The public API has no compiled Flow run operation.
  # Each call starts from the immutable compiled workflow and gets new state.
  defp run_compiled(flow, compiled, input) do
    {:ok, options} = Exec.Options.validate_flow([max_concurrency: 1], :start)
    id = "throughput_#{System.unique_integer([:positive])}"
    span = Exec.Telemetry.start([:jido, :flow], %{execution_id: id, flow: flow.name})

    runner = fn target, params, context, execution_id, owner ->
      Exec.Flow.TargetRunner.run(target, params, context, execution_id, options, flow.name, owner)
    end

    {:ok, execution} =
      Exec.Flow.Engine.start(
        flow,
        compiled,
        input,
        %{},
        %{
          options: options,
          finalizer: &{:ok, &1},
          target_runner: runner,
          execution_id: id,
          lifecycle: %{flow: span}
        }
      )

    {:ok, finished} = Exec.continue(execution)
    finished
  end

  defp measure(benchmark, settings) do
    for _ <- 1..settings.warmup do
      result = benchmark.run.()
      benchmark.check.(result)
    end

    samples =
      for _ <- 1..settings.samples do
        :erlang.garbage_collect(self())
        {:reductions, before_reductions} = Process.info(self(), :reductions)
        started = System.monotonic_time()
        result = benchmark.run.()
        wall_ns = elapsed_ns(started)
        {:reductions, after_reductions} = Process.info(self(), :reductions)
        benchmark.check.(result)

        %{wall_ns: wall_ns, caller_reductions: after_reductions - before_reductions}
      end

    phase = phase_probe(benchmark)
    workflow = benchmark.workflow.(phase.result)
    graph = workflow.graph
    heap_bytes = :erts_debug.size(workflow) * :erlang.system_info(:wordsize)

    wall = distribution(Enum.map(samples, & &1.wall_ns))

    %{
      id: benchmark.id,
      status: "completed",
      kind: benchmark.kind,
      system: benchmark.system,
      values: benchmark.values,
      items: benchmark.items,
      dimensions: Map.take(benchmark, [:groups, :width, :needs]),
      wall_ns: wall,
      caller_reductions: distribution(Enum.map(samples, & &1.caller_reductions)),
      items_per_second: benchmark.items * 1_000_000_000 / wall.median,
      microseconds_per_item: wall.median / benchmark.items / 1_000,
      phase_probe: Map.delete(phase, :result),
      final_graph: %{
        vertices: map_size(graph.vertices),
        edges:
          Enum.reduce(graph.edges, 0, fn {_key, labels}, total -> total + map_size(labels) end),
        workflow_local_heap_bytes: heap_bytes
      }
    }
  end

  defp phase_probe(benchmark) do
    Enum.each(@phase_calls, &:erlang.trace_pattern(&1, true, [:call_time]))
    :erlang.trace(self(), true, [:call])

    try do
      started = System.monotonic_time()
      result = benchmark.run.()
      wall_ns = elapsed_ns(started)
      benchmark.check.(result)

      calls =
        Map.new(@phase_calls, fn {module, function, arity} = mfa ->
          {:call_time, values} = :erlang.trace_info(mfa, :call_time)

          {count, microseconds} =
            case Enum.find(values, fn {pid, _count, _seconds, _micros} -> pid == self() end) do
              nil -> {0, 0}
              {_pid, count, seconds, micros} -> {count, seconds * 1_000_000 + micros}
            end

          {"#{inspect(module)}.#{function}/#{arity}", %{calls: count, microseconds: microseconds}}
        end)

      %{wall_ns: wall_ns, calls: calls, result: result}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(@phase_calls, &:erlang.trace_pattern(&1, false, [:call_time]))
    end
  end

  defp distribution(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      samples: values,
      min: hd(sorted),
      median: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, ceil(count * 0.95) - 1),
      max: List.last(sorted)
    }
  end

  defp comparisons(rows) do
    rows = Enum.filter(rows, &(&1.status == "completed"))
    maps = Enum.filter(rows, &(&1.kind == "map"))

    size_growth =
      maps
      |> Enum.group_by(&{&1.system, &1.values})
      |> Enum.flat_map(fn {_key, group} ->
        group
        |> Enum.sort_by(& &1.items)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [small, large] ->
          %{
            kind: "map_size",
            from: small.id,
            to: large.id,
            item_ratio: large.items / small.items,
            time_ratio: large.wall_ns.median / small.wall_ns.median
          }
        end)
      end)

    partitions =
      Enum.filter(rows, &(&1.kind == "partition")) |> Enum.sort_by(& &1.dimensions.groups)

    partition =
      case partitions do
        [one, many] ->
          [
            %{
              kind: "partition",
              from: one.id,
              to: many.id,
              group_ratio: many.dimensions.groups / one.dimensions.groups,
              time_ratio: many.wall_ns.median / one.wall_ns.median
            }
          ]

        _ ->
          []
      end

    graphs = Enum.filter(rows, &(&1.kind == "graph")) |> Enum.sort_by(& &1.dimensions.needs)

    graph_growth =
      graphs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [sparse, dense] ->
        %{
          kind: "graph_edges",
          from: sparse.id,
          to: dense.id,
          edge_ratio: dense.final_graph.edges / sparse.final_graph.edges,
          time_ratio: dense.wall_ns.median / sparse.wall_ns.median
        }
      end)

    (size_growth ++ partition ++ graph_growth)
    |> Enum.sort_by(&{&1.kind, &1.from, &1.to})
  end

  defp items(size, :unique), do: Enum.to_list(1..size)
  defp items(size, :repeated), do: List.duplicate(7, size)

  defp expect_same_items!(actual, expected) do
    if Enum.frequencies(actual) != Enum.frequencies(expected),
      do: raise("native Runic Map returned incorrect items")
  end

  defp expect!(actual, expected) do
    if actual != expected, do: raise("throughput case returned an incorrect result")
  end

  defp elapsed_ns(started),
    do: (System.monotonic_time() - started) |> System.convert_time_unit(:native, :nanosecond)

  defp source do
    files = [__ENV__.file, Path.expand("../throughput.exs", __DIR__)]

    %{
      commit: command("git", ["rev-parse", "HEAD"]),
      checkout_dirty: command("git", ["status", "--porcelain"]) != "",
      tool_sha256: files |> Enum.map(&File.read!/1) |> hash()
    }
  end

  defp environment do
    %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      runic: Application.spec(:runic, :vsn) |> to_string(),
      schedulers_online: :erlang.system_info(:schedulers_online),
      word_size: :erlang.system_info(:wordsize),
      dependency_lock_sha256: File.read!("mix.lock") |> hash()
    }
  end

  defp command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unavailable"
    end
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp markdown(report) do
    rows =
      for %{status: "completed"} = row <- report.cases do
        ms = Float.round(row.wall_ns.median / 1_000_000, 2)
        p95 = Float.round(row.wall_ns.p95 / 1_000_000, 2)
        rate = Float.round(row.items_per_second, 1)
        reductions = Float.round(row.caller_reductions.median / row.items, 1)
        graph = row.final_graph

        "| #{row.id} | #{ms} | #{p95} | #{rate} | #{reductions} | #{graph.vertices} | #{graph.edges} | #{graph.workflow_local_heap_bytes} |"
      end

    aborted =
      for %{status: "aborted"} = row <- report.cases do
        "| #{row.id} | #{row.items} | #{row.observed_peak_process_bytes} | #{String.replace(row.reason, "\n", " ")} |"
      end

    comparisons =
      for row <- report.comparisons do
        work_ratio =
          Map.get(row, :item_ratio) || Map.get(row, :group_ratio) || Map.get(row, :edge_ratio)

        "| #{row.kind} | #{row.from} | #{row.to} | #{Float.round(work_ratio, 2)} | #{Float.round(row.time_ratio, 2)} |"
      end

    phases =
      for %{status: "completed"} = row <- report.cases,
          {call, data} <- Enum.sort(row.phase_probe.calls) do
        "| #{row.id} | #{call} | #{data.calls} | #{data.microseconds} |"
      end

    """
    # Flow throughput probe

    Commit: `#{report.source.commit}`. Dirty checkout: `#{report.source.checkout_dirty}`.
    Profile: `#{report.settings.profile}`. Elixir: `#{report.environment.elixir}`.
    OTP: `#{report.environment.otp}`. Runic: `#{report.environment.runic}`.
    See `report.json` for raw samples and the full settings.

    | Case | Median ms | p95 ms | Items/s | Caller reductions/item | Final vertices | Final edges | Workflow heap bytes |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{Enum.join(rows, "\n")}

    ## Growth comparisons

    A time ratio near the work ratio suggests linear growth. These are observed ratios, not pass limits.

    | Kind | From | To | Work ratio | Time ratio |
    | --- | --- | --- | ---: | ---: |
    #{Enum.join(comparisons, "\n")}

    ## Aborted cases

    | Case | Items | Observed process bytes | Reason |
    | --- | ---: | ---: | --- |
    #{Enum.join(aborted, "\n")}

    ## Separate Runic call-time probe

    These times are diagnostic. They include tracing cost and can overlap.

    | Case | Call | Count | Microseconds |
    | --- | --- | ---: | ---: |
    #{Enum.join(phases, "\n")}

    ## Limits

    #{Enum.map_join(report.limitations, "\n", &("- " <> &1))}
    """
  end
end
