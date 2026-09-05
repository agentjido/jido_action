# Execution Benchmarks

Use these development tools to compare execution cost before a runtime change.
The tools do not change the package API. No downstream migration is required.
They need Elixir 1.18 or later, a supported OTP release, Git, and the development
dependencies in `mix.lock`. No profiler or extra dependency is required.

Run commands from the package root. Keep the scheduler count, runtime, machine,
Mix environment, and benchmark source the same for a comparison.

```bash
mix deps.get
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/before
```

The default `short` profile runs 57 cases: 4 nodes, 3 warm-up calls, and 15 timing
samples per case. It takes one separate resource sample per case. To run the
larger, bounded profile:

```bash
ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile scale --output bench/results/scale
```

The `scale` profile uses 2, 8, and 16 nodes, 5 warm-up calls, and 30 timing samples.
Fixtures reject graph sizes outside 1 through 32. Term transfer stops if the
estimated flat heap exceeds 64 MiB. Run larger workloads only after you review
the smaller results. A safety timeout fails a stuck probe; it is not a speed
threshold.

## Workloads And Boundaries

All workloads use the same deterministic echo Action and have no network work.
Each accepted warm-up, timing sample, and resource sample must return the
expected result. Each Flow output contains every authored node result.

| Workload | Measured operation |
| --- | --- |
| `action/direct` | Direct `run/2` callback; no Exec validation or lifecycle. |
| `action/run` | `Jido.Exec.run/4` with the default infinite timeout. |
| `action/finite_timeout` | `Jido.Exec.run/4` with a 30-second complete-call limit. |
| `action/async_await` | Start an async call and await it in its owner process. |
| `serial/*` | A chain of result dependencies, concurrency 1. |
| `parallel/*` | Independent Steps, concurrency 4. |
| `subflows/*` | Repeated instances of the same one-Step child Flow, concurrency 4. |

Every Flow shape has five separate measurements:

- `validate`: `Jido.Flow.validate_executable/1`.
- `compile`: `Jido.Flow.compile/1`, which also validates. It is not a pure compiler-only measurement.
- `run`: the complete public `Jido.Exec.run/4` call, including preparation.
- `prepared_reuse`: reuse one compiled graph with fresh execution state per call.
- `paused_continue`: call `continue/1` on a fresh paused execution created outside the timer.

There is no public API that runs a compiled graph. The `prepared_reuse` case
uses an internal adapter for these empty-schema fixtures. It uses the normal
engine and target runner, but omits public target/input validation and graph
compilation. It is a lower-level comparison, not a promised API or cache. The
adapter must be checked when internal interfaces change. It never reuses an
Execution revision or replaces the revision guard.

The input value is either an integer, a map with 1,000 integer entries, or a
1 MiB binary. The same values pass through all call paths. A Flow holds all
node results until completion. Retained-term measurements include the input,
Flow, and compiled graph for Flow cases; Action cases include their input.

## Measurement Method

The runner warms every case and completes all timing runs before resource
tracing starts. Loaded fixture modules and warm calls preload execution paths.
Each timing case runs in its own monitored caller process. Samples for that case
share the caller and its natural garbage collection. The monotonic clock covers
only the measured operation. Setup and result assertions are outside the timer.
Raw samples, minimum, upper median, mean, p95, and maximum are in the JSON file.
Caller reduction counts exclude work in other processes.

Resource runs use a separate caller and a dedicated Task.Supervisor. Fixtures
pass `task_supervisor: JidoActionBench.TaskSupervisor` to Exec. Spawn
tracing follows both roots and their descendants. The roots and observer do not
count as helper starts. Workers stop at explicit callback barriers. The observer
uses a trace-delivery barrier, samples memory, then releases each worker. A paused
case also has a barrier after `start/4`. Completion uses process monitors and
another trace barrier, including helpers that start during cleanup. If a probe
fails, it stops the caller and observed descendants, confirms their termination,
and then returns the failure. It does not first wait for normal helper completion.
No sleep or
global process-count difference establishes cleanup.

Resource runs include setup. Their memory data does not have the same boundary
as paused-continue timing. The following metrics have different meanings:

| Metric | Meaning and limit |
| --- | --- |
| Process memory | Sum of observed caller and helper `Process.info(:memory)` values. Includes process overhead. |
| Process heap | Sum of observed `total_heap_size` values, in bytes. |
| Shared binary memory | Bytes in unique observed off-heap binary references. Binaries shared outside the execution are not exclusively owned. |
| VM memory | Whole-VM total, process, and binary memory. Includes tools and unrelated work. |
| Observed peak | Largest sampled value at start, callback/pause barriers, and completion. Short allocations can be missed. Different metric maxima can occur at different samples. |
| Local term heap | `:erts_debug.size(term)` times word size, with local sharing. |
| Flat term heap | `:erts_debug.flat_size(term)` times word size, without sharing. Excludes off-heap binary payloads. |
| Copied term heap | Flat heap size in a monitored receiver after an actual message transfer. |
| External bytes | `:erlang.external_size/1`; includes the external term representation, not actual message-copy cost. |
| Receiver memory | Receiver process memory after transfer, including overhead. |

Exact memory peaks and complete helper reduction totals are unavailable and
have explicit `null` fields. Results include the commit, source state, tool
hash, dependency lock hash, Elixir, OTP/ERTS, OS, CPU, architecture, word size,
schedulers, warm-up count, sample count, method, and measurement limits.

## Save And Compare Results

Each command writes `report.json` and `report.md`. Generated reports are ignored
under `bench/results/`. Keep machine-specific results with review evidence,
outside ordinary source commits.

Record the initial runtime baseline at commit
`99cebd3f2ebc1137ae8fefb84c8292b1064de8e1`. To measure an older revision, use a
separate checkout of that revision with its own build and dependencies. Run the
same benchmark scripts by absolute path from that checkout. The scripts report
the current working checkout as the measured source and hash their own source.
Do not change the runtime and benchmark tools in the same comparison.

The historical baseline uses the scripts at
`2f42eef1fd547bcddfc33a0a3068e4150c6a1331`, which pass the former `jido:` option.
Current scripts require the explicit supervisor API from #237. Keep the original
baseline reports and scripts. Their tool hash differs from the current tools,
so the comparison command rejects ratios between those report sets.

After the candidate change, repeat the same profile and output to another path:

```bash
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/after
ERL_FLAGS='+S 2:2' mix run bench/compare.exs \
  bench/results/before/report.json bench/results/after/report.json \
  bench/results/comparison.md
```

The comparison joins case IDs and rejects different environments, settings,
methods, tool hashes, or case sets. Inspect the runtime source state too. A ratio is candidate
median divided by baseline median. A smaller number alone does not prove a
speedup. Shared-host load, CPU frequency, scheduling, and garbage collection
can change timing. Repeat reports on an idle host before making a performance
claim. CI has no fixed wall-time pass threshold.

## Smoke Check And Deferred Work

```bash
ERL_FLAGS='+S 2:2' mix test test/bench/execution_bench_test.exs \
  test/jido_exec/runnable_capture_test.exs test/jido_flow/compiler/capture_test.exs
ERL_FLAGS='+S 2:2' mix run bench/run.exs --profile smoke
```

The `smoke` profile uses small input, sizes 2 and 6, one warm-up call, and two
timing samples. It checks results, monitored cleanup, actual graph transfer,
and bounded graph-copy growth. CI runs it after the full coverage suite on the
supported runtime matrix. The merged compiler-capture and runnable-capture
regressions remain unchanged in that suite.

Map, Reduce, Iterate, continuations, concurrent callers, and detailed failures
are deferred. This first stage does not measure durable execution, saturation,
production capacity, or exact allocation totals. It does not redesign execution
ownership, cancellation, or revision guards.
