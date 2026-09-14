# Load verification

Run `mix test.load` from `jido_action`. This opt-in suite checks deep and wide
Flows, a 1,000-item Map, exact work counts, input order, worker limits, and
owned Task cleanup. It runs 60 synchronous and asynchronous calls, plus a
seeded 28-case sequence with step-wise, timeout, cancel, and fault outcomes.
It checks six concurrent callers on one Task.Supervisor and resource counts
after each terminal outcome. It does not use elapsed time as a pass condition.

The default workload seed is `20260914`. To replay another seed, run
`JIDO_ACTION_LOAD_SEED=20260915 mix test.load`. A failure reports its seed,
workload, or call index. Run `sh test/load/burn_in.sh 10` for ten fresh BEAM
runs with consecutive seeds. Each `mix` invocation starts a new VM. Stop on
the first failure; do not use a successful later run to dismiss it. The seeded
sequence reports the first failing case index, input size, mode, and seed. Set
`JIDO_ACTION_LOAD_CASE=<index>` with the reported seed to replay only that
sequence case in a new BEAM.

Before a V3 release, run `sh test/load/burn_in.sh 10` on each of these local
runtime pairs: Elixir 1.18/OTP 27, Elixir 1.19/OTP 28, and Elixir 1.20/OTP 29.
Each run starts a new BEAM with a new seed. The selected pairs cover the
minimum, middle, and current Elixir lines with compatible OTP lines; they do
not test every supported pair.

Use `test/bench` for performance comparisons. Do not treat this suite as a
throughput benchmark.

## Separate throughput stress run

Run `mix run test/load/throughput.exs --profile smoke` to check the runner.
Run `mix run test/load/throughput.exs --profile stress` for the full Map size
curve through 8,192 items. The `extreme` profile has a 16,384-item case and
larger graph cases. These runs are opt-in and do not run with `mix test.load`.
Use `--filter map/jido/unique/2048` to select one case. Use `--output DIR` to
change the report directory. By default, JSON and Markdown reports go under
ignored `test/load/results/`. Run
`mix test test/load/throughput_test.exs --only throughput` to
check the runner and all smoke cases without a speed limit.

The runner compares native Runic Map/Reduce with Jido Flow Map, repeats values,
and changes Map size. It also runs the same item count as one Map or many Maps,
changes graph dependencies while node count stays fixed, and reuses one compiled
Flow for many inputs. Every run checks its result. The report has raw time
samples, median and 95th-percentile time, items per second, reductions per
item, graph size, and a separate Runic call-time probe. The probe measures
Runic planning, dispatch preparation, runnable execution, and result
application in the caller process. Its times include tracing cost and can
overlap. Do not subtract native Runic time from Jido Flow time as an exact Jido
cost: the two graphs do not have identical work. Compare reports only when
the machine, runtime, dependency versions, and workload settings match.

The runner writes `progress.jsonl` after each case, so earlier results remain
available if a later case stops. It observes the case process every 100 ms and
stops a case if that process exceeds the profile's memory limit (2 GiB for
`stress`, 4 GiB for `extreme`). Use `--max-memory-mb N` to change this limit.
The limit protects the host; it is not a performance pass condition. An
incorrect result fails the run and leaves the completed case rows in the
progress file.
