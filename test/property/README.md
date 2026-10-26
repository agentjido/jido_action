# Property and fuzz tests

Run the short property suite or the full fuzz suite from the package root:

```sh
mix test.property
mix test.fuzz
mix test.ci --warnings-as-errors
mix test.all --warnings-as-errors
```

`mix test.ci` selects the default tests plus property, fuzz, system, and load
tests. `mix test.all` also includes authoring tests. Both commands require a
finished, passing property report and measurements for every required fuzz
case. CI uses `mix test.ci`; release preflight uses `mix test.all`. Covenant
reports and mutation checks run separately with the commands in
[the contract check instructions](../contracts/README.md).

The [public contract register](../../guides/public-contracts.md#fuzz-cases)
lists all 15 required fuzz cases and their bounds. The required ID list is in
`support/report.exs`; a test checks that the register has the same IDs.
All generators use StreamData. There is no second property framework.

## Execution checks

The short component properties compare serial and concurrent `Jido.Exec.run`
results. They do not claim managed execution coverage.

The five Runner fuzz cases use current public APIs:

- `runner_schedules` controls Map completion order at concurrency limits 1–4.
  It checks exact output and effect order, duplicate item values, cancellation,
  stop, worker exit, and absence of later admission.
- `nested_runner_failures` varies returned errors, raises, and throws in a
  nested Map. It checks failure selection, admission limits, worker exit,
  blocked dependent work, and discarded effects.
- `runner_histories` advances a manual execution, checkpoints completed work,
  stops it, and resumes it with `Jido.Exec.resume`. The cut varies from one
  completed Action to the penultimate Action. Generated commands read,
  checkpoint, or stop and resume again. Completion uses manual steps or
  `Runic.Runner.continue`. Chain, Map, Iterate, nested Flow, and Invoke cases
  check exact calls and prove that completed Actions do not run again.
  Each sample also checks the managed portable-data boundary.
- `invoke_chains` compares immediate, automatic, and manual execution.
  Chains select Action or Flow terminals and check success, returned errors,
  timeout, exact calls, and ordered or discarded effects.
- `runner_telemetry` varies retry counts and terminal outcomes across all
  three execution modes. It checks Action attempt spans, stable activation
  identity, distinct attempt identities, bounded metadata, one immediate Flow
  span, and managed Runic runnable events. Runic emits an exception event for
  a failed runnable.

Manual steps use a small observer of the public Runic Scheduler callback.
This callback confirms completion of a scheduler unit, including skipped
units. A unit is not always an authored Action. It can be input, output, or
collection work. The observer delegates all admission choices to Runic's
Default scheduler.

## Generation and expected results

Fuzz tests use ordinary ExUnit `test` declarations with `:fuzz`, `fuzz_id`,
contract, and budget tags. StreamData properties add `:property` themselves;
using them for fuzz would cause selection overlap.

Generation is bounded by both sample count and discovery time. Existing data
cases allow five minutes; Runner cases allow one minute. Every fuzz test has
a 15-minute ExUnit timeout. Shrinking permits at most 200 attempts. Fixed
examples and saved failures run before new generation. Readiness and cleanup
checks have finite message timeouts and use no sleeps.

Graph arithmetic, list folds, state transitions, callback records, and public
error fields provide independent expected results. Codec round trips add
consistency checks. A Step wire-format oracle is written independently of the
encoder. Other component formats retain focused Codec tests.

Cases with changed input grammars have new IDs. Old local counterexamples
remain available for inspection; they do not enter a different grammar.

## Reports and replay

The run report is `_build/test/property-report.json`. A custom
`MIX_BUILD_PATH` changes its root. The report records source and runtime data,
ExUnit selection and seed, contract evidence, and fuzz measurements.

Measurements distinguish generated samples, fixed examples, saved replays,
shrink attempts, and repeat checks of a reduced failure. Observation counts
come only from passing samples, examples, and replays. They do not guide
input generation or prove complete coverage.

The report rejects invalid counts or budgets, unknown contract IDs, invalid
case tags, duplicate measurements, failed measurements, and missing or
mismatched measurements for a passed measured test. Files from earlier runs
are ignored. The full fuzz gate also rejects any missing required fuzz ID.
Focused test runs can produce a partial report without satisfying that gate.

Reduced failures are saved as plain JSON under
`_build/test/property-counterexamples/<case-id>`. Each file records its input,
seed, contracts, and source/runtime metadata. The helper replays saved inputs
before generation and checks a newly reduced failure again. An unstable repeat
still fails the test. Re-run the owning test with `--only fuzz` to replay it.

Inspect saved failures before removal. Promote useful inputs to fixed examples
or reviewed files under `test/property/corpus/<case-id>`. No reviewed corpus is
currently checked in. Temporary writes use unique names and atomic rename.
Support tests check shrinking, replay, malformed input, failure stability,
budgets, report validation, and cleanup. Their deliberate probe failures in
console output are expected when those tests pass.

## Ownership and limits

Immediate samples pass their private Task Supervisor to Exec and monitor
callback processes. Managed samples use test-supervised Runners and portable
context names. Each execution has a unique ID and message token. Cleanup stops
Workers, confirms process exit, and drains only that execution's messages.
Telemetry handlers are detached in `after`.

The suite controls callback completion order. It does not search all BEAM
scheduler interleavings. It has no coverage-guided engine or mutation score.
Static contract tags index evidence; they do not prove every clause of a
contract. Full validator diagnostics, hard task crashes, caller death,
persistence failure, and telemetry during forced process termination retain
focused tests under `test/jido_exec`. Recovery tests use Runic's local Store;
they do not prove external effect delivery or exactly-once execution.
