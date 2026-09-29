defmodule JidoActionBench.Fixtures do
  def git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _ -> nil
    end
  end

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
end

Code.require_file("support/measure.exs", __DIR__)

defmodule JidoActionBench.Echo do
  use Jido.Action, name: "comparison_echo"

  def run(params, context) do
    JidoActionBench.Fixtures.barrier(context)
    {:ok, params}
  end
end

defmodule JidoActionBench.ValidatedEcho do
  use Jido.Action,
    name: "comparison_validated_echo",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  def run(params, context) do
    JidoActionBench.Fixtures.barrier(context)
    {:ok, params}
  end
end

defmodule JidoActionBench.CachedValidatedEcho do
  @comparison_schema Zoi.object(%{value: Zoi.integer()})
  use Jido.Action,
    name: "comparison_cached_validated_echo",
    schema: @comparison_schema,
    output_schema: @comparison_schema

  def run(params, context) do
    JidoActionBench.Fixtures.barrier(context)
    {:ok, params}
  end
end

[version, destination] = System.argv()
unless version in ["v2", "v3"], do: raise(ArgumentError, "version must be v2 or v3")
alias JidoActionBench.Measure
Logger.configure(level: :warning)
{:ok, supervisor} = Task.Supervisor.start_link(name: JidoActionBench.TaskSupervisor)

base_opts =
  if version == "v2",
    do: [jido: JidoActionBench, max_retries: 0],
    else: [task_supervisor: JidoActionBench.TaskSupervisor]

workloads =
  for {label, target, params} <- [
        {"empty_schema/small", JidoActionBench.Echo, %{value: 42}},
        {"zoi_integer/small", JidoActionBench.ValidatedEcho, %{value: 42}},
        {"cached_zoi_integer/small", JidoActionBench.CachedValidatedEcho, %{value: 42}},
        {"empty_schema/map1000", JidoActionBench.Echo, %{value: Map.new(1..1000, &{&1, &1 * 2})}}
      ],
      mode <- [:direct, :timed, :async] do
    timeout = if mode == :direct, do: if(version == "v2", do: 0, else: :infinity), else: 30_000
    opts = Keyword.put(base_opts, :timeout, timeout)

    %{
      id: "#{label}/#{mode}",
      setup: fn context -> context end,
      run: fn context ->
        if mode == :async do
          target |> Jido.Exec.run_async(params, context, opts) |> Jido.Exec.await(:infinity)
        else
          Jido.Exec.run(target, params, context, opts)
        end
      end,
      check: fn result ->
        if result != {:ok, params}, do: raise("wrong result: #{inspect(result)}")
        :ok
      end
    }
  end

workloads =
  if filter = System.get_env("JIDO_COMPARE_FILTER") do
    Enum.filter(workloads, &String.starts_with?(&1.id, filter))
  else
    workloads
  end

if workloads == [], do: raise(ArgumentError, "no comparison workloads match the filter")

# All timings run before the first trace probe. Both versions use normal telemetry
# with no handlers. Time limits match, and V2 retries are disabled.
timings = Map.new(workloads, fn w -> {w.id, Measure.timing(w, 200, 1000)} end)

cases =
  for w <- workloads, do: %{id: w.id, timing: timings[w.id], resources: Measure.resources(w, 7)}

commit =
  System.get_env("JIDO_COMPARE_REVISION") || JidoActionBench.Fixtures.git(["rev-parse", "HEAD"])

status = JidoActionBench.Fixtures.git(["status", "--porcelain"])

report = %{
  source: %{
    commit: commit,
    checkout_dirty: if(is_nil(status), do: nil, else: status != ""),
    lock_sha256: :crypto.hash(:sha256, File.read!("mix.lock")) |> Base.encode16(case: :lower)
  },
  version: version,
  elixir: System.version(),
  otp: System.otp_release(),
  schedulers: :erlang.system_info(:schedulers_online),
  warmup: 200,
  samples: 1000,
  resource_samples: 7,
  cases: cases
}

File.write!(destination, JSON.encode!(report))
Supervisor.stop(supervisor)
