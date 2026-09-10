Code.require_file("fixtures.exs", __DIR__)
Code.require_file("measure.exs", __DIR__)
Code.require_file("report.exs", __DIR__)
Code.require_file("memory_cases.exs", __DIR__)
Code.require_file("component_cases.exs", __DIR__)
Code.require_file("boundary_cases.exs", __DIR__)
Code.require_file("lifecycle_cases.exs", __DIR__)

defmodule JidoActionBench.Suite do
  @moduledoc false
  alias JidoActionBench.{
    BoundaryCases,
    ComponentCases,
    Fixtures,
    LifecycleCases,
    Measure,
    MemoryCases,
    Report
  }

  def run(profile, filter \\ nil) do
    settings = Map.put(settings(profile), :filter, filter)
    {:ok, supervisor} = Task.Supervisor.start_link(name: JidoActionBench.TaskSupervisor)

    try do
      :ok = check_growth!()

      workloads = workloads(profile)

      workloads =
        if filter, do: Enum.filter(workloads, &String.contains?(&1.id, filter)), else: workloads

      if workloads == [], do: raise(ArgumentError, "no benchmark cases match the filter")

      # The untimed growth preflight is complete. Time every workload before
      # its traced resource run and retained-term transfer probe.
      IO.puts("Timing #{length(workloads)} cases without tracing...")

      timings =
        Map.new(workloads, fn workload ->
          {workload.id, Measure.timing(workload, settings.warmup, settings.samples)}
        end)

      IO.puts("Tracing ownership and sampling memory in separate calls...")

      cases =
        Enum.map(workloads, fn workload ->
          %{
            id: workload.id,
            timing: Map.fetch!(timings, workload.id),
            resources: Measure.resources(workload, settings.resource_samples),
            retained_terms: Measure.retained(workload)
          }
        end)

      %{
        schema_version: 3,
        source: source(),
        environment: environment(),
        settings: settings,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        method:
          "untraced monotonic clock; caller reductions; traced ownership and GC events; barrier reduction and memory samples; monitored execution-term transfer",
        limitations: Report.limitations(),
        growth_check: "passed: compiled serial, parallel, and Subflow graphs at sizes 2 and 6",
        cases: cases
      }
    after
      Supervisor.stop(supervisor)
    end
  end

  def workloads(profile) do
    settings = settings(profile)
    standard = Fixtures.workloads(settings.sizes, settings.payloads)

    expanded =
      ComponentCases.workloads() ++ BoundaryCases.workloads() ++ LifecycleCases.workloads()

    if profile == "smoke" do
      smoke = [
        "component/map/1/continue",
        "component/reduce/1/continue",
        "component/iterate/1/continue",
        "component/choice/0/continue",
        "component/dispatch/run",
        "expr/validate/nested",
        "schema/struct/true/200",
        "codec/encode_explicit/16",
        "lifecycle/cancel"
      ]

      standard ++ Enum.filter(expanded, &(&1.id in smoke))
    else
      standard ++ MemoryCases.workloads() ++ expanded
    end
  end

  def write!(report, directory) do
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "report.json"), JSON.encode!(report))
    File.write!(Path.join(directory, "report.md"), Report.markdown(report))
  end

  def check_growth! do
    for shape <- [:serial, :parallel, :subflows] do
      [small, large] =
        for count <- [2, 6] do
          {:ok, compiled} = Jido.Flow.compile(Fixtures.graph(shape, count))
          # This bound accompanies the broader merged capture regressions, which
          # the documented smoke command runs without changing their fixtures.
          bytes = :erts_debug.flat_size(compiled) * :erlang.system_info(:wordsize)
          if bytes > 64 * 1_048_576, do: raise("compiled graph exceeds the safe transfer bound")
          copied = Measure.term_size(compiled)
          if copied.copied_flat_heap_bytes != bytes, do: raise("copied graph size differs")
          bytes
        end

      if large >= small * 4, do: raise("#{shape} graph copy growth exceeds the bound")
    end

    :ok
  end

  defp settings("short"),
    do: %{
      profile: "short",
      sizes: [4],
      payloads: [:small, :large_map, :large_binary],
      warmup: 3,
      samples: 15,
      resource_samples: 3
    }

  defp settings("scale"),
    do: %{
      profile: "scale",
      sizes: [2, 8, 16],
      payloads: [:small, :large_map, :large_binary],
      warmup: 5,
      samples: 30,
      resource_samples: 3
    }

  defp settings("smoke"),
    do: %{
      profile: "smoke",
      sizes: [2, 6],
      payloads: [:small],
      warmup: 1,
      samples: 2,
      resource_samples: 1
    }

  defp settings("backlog"),
    do: %{
      profile: "backlog",
      sizes: [4],
      payloads: [:small],
      warmup: 3,
      samples: 15,
      resource_samples: 3
    }

  defp settings(_), do: raise(ArgumentError, "profile must be short, scale, smoke, or backlog")

  defp source do
    files = Path.wildcard(Path.expand("../**/*.exs", __DIR__)) |> Enum.sort()
    tool_sha = files |> Enum.map(&File.read!/1) |> hash()

    %{
      commit: command("git", ["rev-parse", "HEAD"]),
      runtime_dirty:
        command("git", ["status", "--porcelain", "--", "lib", "config", "mix.exs", "mix.lock"]) !=
          "",
      checkout_dirty: command("git", ["status", "--porcelain"]) != "",
      tool_sha256: tool_sha
    }
  end

  defp environment do
    %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      erts: :erlang.system_info(:system_version) |> List.to_string() |> String.trim(),
      os: command("uname", ["-srv"]),
      architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      cpu: cpu(),
      hostname: command("hostname", []),
      word_size: :erlang.system_info(:wordsize),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      logical_processors: :erlang.system_info(:logical_processors_available),
      mix_env: to_string(Mix.env()),
      dependency_lock_sha256: File.read!("mix.lock") |> hash()
    }
  end

  defp cpu do
    case :os.type() do
      {:unix, :darwin} ->
        command("sysctl", ["-n", "machdep.cpu.brand_string"])

      {:unix, :linux} ->
        case File.read("/proc/cpuinfo") do
          {:ok, text} ->
            text
            |> String.split("\n")
            |> Enum.find("unavailable", &String.starts_with?(&1, "model name"))

          _ ->
            "unavailable"
        end

      _ ->
        "unavailable"
    end
  end

  defp command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
