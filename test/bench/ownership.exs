Code.require_file("test/bench/support/suite.exs")
alias JidoActionBench.{Fixtures, Measure, ComponentCases, Echo}
alias Jido.Exec
{:ok, sup} = Task.Supervisor.start_link(name: JidoActionBench.TaskSupervisor)
opts = [task_supervisor: JidoActionBench.TaskSupervisor, max_concurrency: 1]

small =
  for mode <- [:sync, :timed, :async, :serial] do
    target = if mode == :serial, do: Fixtures.graph(:serial, 3), else: Echo

    %{
      id: to_string(mode),
      setup: fn ctx -> ctx end,
      run: fn ctx ->
        if mode == :async do
          Exec.await(Exec.run_async(target, %{value: 42}, ctx, opts), :infinity)
        else
          run_opts = if mode == :timed, do: [timeout: 30_000] ++ opts, else: opts
          Exec.run(target, %{value: 42}, ctx, run_opts)
        end
      end,
      check: fn {:ok, _} -> :ok end
    }
  end

large =
  for kind <- [:map, :reduce], concurrency <- [1, 8] do
    flow = ComponentCases.graph(kind, 256)

    %{
      id: "#{kind}/256/c#{concurrency}",
      setup: fn ctx -> ctx end,
      run: fn ctx ->
        Exec.run(
          flow,
          %{items: Enum.to_list(1..256)},
          ctx,
          Keyword.put(opts, :max_concurrency, concurrency)
        )
      end,
      check: fn {:ok, _} -> :ok end
    }
  end

# All time samples are untraced; memory and process probes use explicit barriers.
cases =
  for w <- small ++ large do
    %{id: w.id, timing: Measure.timing(w, 10, 50), resources: Measure.resources(w, 3)}
  end

File.write!(
  hd(System.argv()),
  JSON.encode!(%{elixir: System.version(), otp: System.otp_release(), cases: cases})
)

Supervisor.stop(sup)
