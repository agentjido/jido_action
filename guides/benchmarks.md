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
| `short` (default) | 57 | 4 | 3 | 15 |
| `scale` | 171 | 2, 8, 16 | 5 | 30 |
| `smoke` | 38 | 2, 6 | 1 | 2 |

Select a profile with `--profile scale` or `--profile smoke`. Short and scale
use small data, a 1,000-entry map, and a 1 MiB binary. Smoke uses small data.
Each case also takes one separate resource sample. Fixtures allow 1–32 nodes;
a transfer probe rejects a flat heap above 64 MiB.

## What Is Measured

The Action cases cover a direct callback, Exec, a finite complete-call timeout,
and async start/await. Serial, parallel, and repeated Subflow graphs each
measure validation, compilation, complete execution, compiled-graph reuse,
and continuation of a paused execution. Every sample must return the expected
result. The Actions perform no network work.

Compilation includes validation. The internal compiled-graph adapter omits
public target/input validation and creates a fresh execution each time. It is
not a public cache API. Paused-continue setup is outside the timing boundary;
resource measurements include setup.

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
| Observed peak | Largest barrier sample; short allocations can be missed. |
| Local and flat term heap | Heap with and without local sharing; excludes binary payloads. |
| Copied term heap and receiver memory | Measured after an actual process transfer. |
| External bytes | External term encoding size, not message-copy cost. |

Exact memory peaks and total helper reductions are unavailable. Reports mark
these fields as null and record runtime, machine, commit, tool hash, lockfile
hash, sample settings, and measurement limits.

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
Host load and garbage collection can change results; repeat measurements
before making a performance claim. CI has no fixed timing threshold.

The smoke profile runs in CI and checks results, cleanup, graph transfer, and
bounded copy growth. The suite does not yet cover Map, Reduce, Iterate,
continuations, concurrent callers, or a complete failure matrix.
