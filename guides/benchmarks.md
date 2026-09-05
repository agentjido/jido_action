# Execution Benchmarks

Run from the package root with Elixir 1.18 or later and the development
dependencies from `mix.lock`:

```bash
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/before
```

Each run writes `report.json` and `report.md`. Reports under `bench/results/`
are ignored by Git.

| Profile | Cases | Graph sizes | Warm-up calls | Timing samples |
| --- | ---: | --- | ---: | ---: |
| `short` (default) | 222 | 4 | 3 | 15 |
| `scale` | 312 | 2, 8, 16 | 5 | 30 |
| `smoke` | 43 | 2, 6 | 1 | 2 |
| `backlog` | 184 | 4 | 3 | 15 |

Select a profile with `--profile scale` or `--profile smoke`. Short and scale
use small data, a 1,000-entry map, and a 1 MiB binary. Smoke uses small data.
Short and scale take three separate resource samples per case; smoke takes
one. Reports keep the raw samples and field medians. Action cases run once per
payload, since graph size does not affect them. Standard graph fixtures allow
1–32 nodes; a transfer probe rejects a flat heap above 64 MiB.

`backlog` keeps small standard payloads and all focused cases. Use
`--filter SUBSTRING` to select case IDs. Comparisons require the same filter.

## What Is Measured

The Action cases cover a direct callback, Exec, a finite complete-call timeout,
and async start/await. Serial, parallel, and repeated Subflow graphs each
measure validation, compilation, complete execution, compiled-graph reuse,
and continuation of a paused execution. Every sample must return the expected
result. The Actions perform no network work.

Short and scale also run 18 fixed memory cases, outside the graph-size matrix:

- Compile and pause four Steps or Subflows with empty metadata, a 5,000-item
  list, or a 1 MiB binary.
- Execute small or large input with a small success result or a fixed error.
  Large input includes a 5,000-item list that the Action does not use.
- Read `Exec.ready/1` 100 times on 16 nodes, retaining the last descriptor list.
- Run one collector after a wave of 32 producers. Collector timing excludes
  the producer wave; resource measurements include it.

The focused cases also cover Map, Reduce, Iterate, Choice, Dispatch,
component metadata, terminal-only output, large context, shared terms, binary
slices, expression walks, schemas, Codec, IDs, and step/wave scheduling.
Lifecycle cases cover cancellation, expired deadlines, caller exit, repeated
async calls with unrelated mailbox messages, and telemetry handlers. The smoke
profile includes nine small cases from these groups. Larger collection cases
use up to 16 items; they do not establish behavior at unbounded fan-out.

Compilation includes validation. The internal compiled-graph adapter omits
public target/input validation and creates a fresh execution each time. It is
not a public cache API. Paused-continue setup is outside the timing boundary;
resource measurements include setup.
Ready-call timing also excludes completion of its execution; resource
measurements include completion.

Timing samples run without tracing. The clock covers the operation only;
setup and result checks are outside it. Reports include raw samples and
summary statistics. Caller reductions exclude work in helper processes.

Resource samples use a separate caller and Task.Supervisor. Spawn tracing
follows their descendants. Callback and trace-delivery barriers establish
sampling points; process monitors confirm cleanup, including after a failed
probe. Reports separate these quantities:

| Metric | Meaning |
| --- | --- |
| Process memory and heap | Sum across the observed caller and helpers. |
| Shared binary bytes | Unique observed off-heap references; ownership can be shared. |
| VM memory | Whole-VM use, including unrelated work and measurement tools. |
| Observed peak | Largest start, callback, pause, or result barrier sample; short allocations can be missed. |
| Local and flat term heap | Heap with and without local sharing; excludes binary payloads. |
| Copied term heap and receiver memory | Measured after an actual process transfer. |
| External bytes | External term encoding size, not message-copy cost. |

Retained-term probes make a separate checked call. They measure the relevant
Flow, compiled graph, result, or actual paused and finished Execution values.
Failure records are measured separately from the full failed execution.
Paused values are copied after their execution is finished. The Markdown
report shows process memory, binary memory, and named copied-term sizes;
the JSON also keeps every resource sample.

Exact memory peaks and total helper reductions are unavailable. Reports mark
these fields as null and record runtime, machine, commit, tool hash, lockfile
hash, sample settings, and measurement limits.
Resource reports also record owned garbage collections, observed mailbox size,
and reductions sampled at barriers. Observed worker reductions are a lower
bound. They are separate from caller reductions in untraced timing runs.

## Compare Runs

Repeat the same profile on the same idle host and runtime. Use separate
checkouts with separate builds when comparing revisions. Keep the benchmark
scripts unchanged; they can be run by absolute path from another checkout.

```bash
ERL_FLAGS='+S 2:2' mix run bench/run.exs --output bench/results/after
ERL_FLAGS='+S 2:2' mix run bench/compare.exs \
  bench/results/before/report.json bench/results/after/report.json \
  bench/results/comparison.md
```

Comparison requires matching environments, settings, methods, tool hashes,
and case IDs. A ratio is the candidate median divided by the baseline median.
Schema version 3 adds garbage-collection tracing and observed worker reductions.
Rerun both revisions with the same benchmark scripts when changing the schema.
Host load and garbage collection can change results; repeat measurements
before making a performance claim. CI has no fixed timing threshold.

The smoke profile runs in CI and checks results, cleanup, graph transfer, and
bounded copy growth. The suite does not cover distributed callers or a complete
failure matrix.

For release measurements, use the existing isolated consumer fixture:

```bash
ERL_FLAGS='+S 2:2' MIX_ENV=test mix run bench/release.exs bench/results/release
```

This writes `release.json` with release size, generated module size, memory
after startup, first-call time, and warm timings. It compares two-step inline
and explicit Flows in fresh VMs, after removing consumer source. ERTS size and
VM boot time are excluded.
