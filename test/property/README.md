# Public Contract Property Tests

Run from the `jido_action` package root:

```sh
MIX_ENV=test mix deps.get
mix test.property --warnings-as-errors
mix test test/property/flow --only property --seed 123
mix test test/property/execution --only property --trace

# Select only the larger fuzz cases.
mix test.fuzz --warnings-as-errors --seed 123
mix test test/property/flow --only fuzz --seed 456

# Select both suites in one run.
mix test test/property --only property --only fuzz --seed 123
```

Default `mix test` skips `:property` and `:fuzz`, including the fixed revision sequence.
The short revision test starts the PropCheck application only when ExUnit
explicitly includes `:property`. The fuzz revision case loads the model and uses
PropCheck functions without starting that application. Default and fuzz-only
runs leave the short suite's saved counterexample store unchanged. Use `--only property` or `--only fuzz` when
running an individual file. `--include` also runs other tests allowed by the filters.

## Organization

Group by public API area. Contract IDs belong in tags, not directory names:

```text
test/property/
  action/          # Validation, output, errors
  instruction/     # Call data and executable targets
  expression/      # Fixed grammar, operators, limits
  flow/            # Authoring, graphs, components, inline work
  storage/         # Codec and Registry
  execution/       # Revisions, concurrency, async, continuations, telemetry
  support/         # Runtime assertions and optional report formatter
  corpus/          # Optional reviewed JSON failures, under a property ID
  report_test.exs  # Fixed checks of report behavior; no public contract claim
  fuzz_support_test.exs # Shrink, replay, cleanup, and unstable-failure checks
```

Tests declare `contracts` and, where classes are forced, `contract_cases` tags.
The [public register](../../guides/public-contracts.md) states the promises,
oracles, and remaining limits. Each selected run writes
`_build/test/property-report.json`. It reports passed evidence and forced case
IDs, failed/skipped tests, missing contract evidence, unknown contract IDs,
invalid case IDs, revision, dirty state, and runtime. Case IDs are stable strings.
They describe fixed loops and sequences in passing tests, not statistical transition coverage.
Random command frequencies make no forced-case claim. The revision fuzz case
forces its declared cases through fixed histories before random generation.
`contract_evidence_by_suite` reports property and fuzz evidence separately, so a
short property cannot fill a fuzz gap. The register's
[15-case fuzz plan](../../guides/public-contracts.md#fuzz-contract-plan) maps
each implemented case to public contracts and expected checks.

StreamData supplies generated values inside required case classes. Named graph
shapes, dependency sources, callback failure forms, routing cases, concurrency
limits, and execution modes are forced in their owning properties.
Tests use independent arithmetic, list-fold, and state models where useful.
PropCheck supplies valid command sequences and sequence shrinking for revisions.
Existing authoring properties stay in their suite; there is no framework migration.

## Fuzz Experiments

The workflow takes ideas from the
[Hegel Elixir examples](https://github.com/ghuntley/hegel-erlang/tree/main/examples/elixir):
generate inputs, observe useful case classes, reduce a failure, save it, and replay
it. Fourteen cases use public `StreamData.check_all/3`. The revision case uses
PropCheck's public command generator, shrinker, and replay functions.
There is no Hegel engine dependency or new generator engine.

`:property` selects the short checks. `:fuzz` selects fifteen larger cases.
A fuzz case has only the `:fuzz` selection tag, so `--only property` does not
select it. The original graph, mixed-component, and async experiments have
paired short cases with the same assertions and shared saved inputs.

| Fuzz ID | Generated samples or histories | Input bounds |
| --- | ---: | --- |
| `graph_semantics` | 600 | 12 nodes; short case: 60 samples, 6 nodes |
| `mixed_components` | 300 | 10 items; short case: 30 samples, 5 items |
| `async_schedules` | 400 | 8 workers; short case: 40 samples, 6 workers |
| `codec_mutations` | 300 | Selected invalid fields and depth/width/total-node boundaries |
| `iterate_state` | 200 | 12 iterations; all four execution modes |
| `nested_execution_failures` | 250 | 10 items per child, up to 3 children, limits 1–3 |
| `codec_portability` | 300 | Portable trees, all component kinds, both stored versions |
| `expression_trees` | 1,000 | Numeric depth 5, Boolean depth 2, explicit invalid limits |
| `action_boundaries` | 250 | 30 output items; all callback failure and envelope forms |
| `instruction_targets` | 500 | Optional key sets, nested overrides, all three target forms |
| `graph_rejections` | 300 | 12 nodes; all selected defect classes per sample |
| `authoring_equivalence` | 100 | 8 source nodes; three dependency forms per sample |
| `revision_histories` | 500 | PropCheck size 100; 12 nodes; valid state-dependent commands |
| `continuation_chains` | 250 | 12 Action/Dispatch links; fixed terminal timeout cases |
| `telemetry_lifecycle` | 180 | 12 items/iterations; core or collection event selection |

These are generation bounds. Fixed examples and saved replays run separately.
Every fuzz case writes measurements into the report's `fuzz` field. The three
paired short cases also write measurements with `variant: "property"`.

Expected results are independent arithmetic, list folds, state transitions,
public error fields, and callback or event counts. Authoring and Codec round
trips supplement those checks. The stored Step wire-format oracle is written
independently of the encoder. The public register describes each case in detail.

Budgets are ordinary ExUnit tags. The test receives them in its context and passes
them to the helper. Change these tags in the owning test to run a larger experiment:

```elixir
@tag :fuzz
@tag max_runs: 2_000, max_run_time: 300_000, timeout: 900_000
@tag contracts: ["FLOW-002", "EFFECT-001"]
test "larger experiment", context do
  Fuzz.check("example", generator(), Map.to_list(context), &assert_example/1)
end
```

Fuzz cases use ordinary `test/3`. StreamData's `property/3` macro adds a
`:property` tag itself, which would also select a fuzz case with `--only property`.

Use the owning test's size tags, such as `max_nodes`, `max_items`, `max_workers`,
`max_iterations`, `max_links`, and PropCheck's `max_size`, to set input bounds. CLI include/exclude filters select tests; they do not
override budget tags. There is no environment profile or global run multiplier.
The short cases allow 10 seconds of discovery and have a 90-second ExUnit timeout.
All fuzz cases have a 15-minute ExUnit timeout. The fourteen StreamData cases
allow 5 minutes of discovery and stop at the run count or time limit, whichever
comes first. The native PropCheck case uses run-count and size limits under the
overall ExUnit timeout; it does not use StreamData's discovery-time option. Larger
timeouts do not force the test to run for the full time budget. The discovery
time limit is checked between samples. ExUnit's overall timeout also bounds
fixed examples, replay, callbacks, shrinking, and cleanup. Worker readiness and
cleanup checks retain their finite limits to detect stalled work.
Run/time limits must be positive integers. Each failed discovery allows
at most 200 shrink attempts; `max_shrinking_steps` can set a non-negative limit.

Each record separates generated attempts, fixed examples, corpus replays, shrink
attempts, and repeat checks of a reduced failure. It also records contract IDs,
declared forced cases, discovery limits, and the ExUnit timeout. Observation counts include only
passing generated/fixed/replayed samples. One sample can report several classes.
Passing shrink attempts do not add evidence. Measurements are stored under
`property-fuzz/<run-id>/<property-id>-<variant>.json` in the Mix build root.
Both variants remain visible when selected together. Files from earlier runs are
not read, including malformed files. A malformed current file makes the finished
report fail and appears in `artifact_errors`. Other properties retain static case
tags only.

The graph generator uses a list of node data and maps parent indexes to earlier
nodes. Thus, removing nodes during shrinking preserves a valid DAG. A generator
that binds a node count to a fixed list can leave a larger reduced graph for the
same fault. Shrinking still does not promise a globally smallest failure.

Worker admission order is not component-name order. The async test observes the
admitted workers, then applies generated release priorities. Saved data contains
logical worker IDs, never PIDs or execution tokens. This controls selected callback
completion orders; it does not replay or search all BEAM scheduler interleavings.
Observations do not guide generation. There is no coverage-guided search, target
score, branch-coverage measurement, or production mutation score.

## What This Strategy Can Prove

Use a contract ID as an evidence index. One passing owner does not prove every
clause of a broad contract. Review the test body and the required cases together.
The contract evidence reads static tags. It cannot prove that a loop ran, that its
assertion was useful, or that every generated class occurred. For that reason, its
case field is named `declared_forced_cases_in_passed_tests`. The separate `fuzz`
observations count completed assertions in the measured cases; they do not
establish complete contract coverage.

Keep independent expected results where practical. Graph arithmetic, list folds,
callback records, and public error fields test behavior without calling the
implementation to calculate the answer. Codec equality is also useful, but a
reader and writer can share a mistake. A small Step document is therefore
written independently and checked in both directions. Other component formats
retain fixed Codec evidence. Identity round trips prove consistency; they do
not independently prove the hash algorithm or every identity distinction.

The two frameworks have separate jobs. StreamData varies data and graph shape.
PropCheck shrinks valid command sequences with state-dependent choices. The
revision model varies steps, waves, current continuation, invalid tokens, old
tokens, old revisions, and reads. Its fuzz variant adds failed terminal states,
foreign tokens, and competing claims with explicit barriers. It uses independent
Steps so that one ready unit is one callback. It does not model Runic support-work
granularity, dependent graphs, or arbitrary parallel histories. Fixed histories
force key transitions; random command frequencies make no coverage claim.

Ready work has no public admission order. For a failed serial wave, the model
checks that callbacks form a distinct subset of the ready work and that the
failing callback is last. It does not require an alphabetical prefix.

Dynamic DSL compilation earns its cost by checking the actual source lowerer
against all three data forms. It uses a bounded set of small Step shapes and a
fixed module name. Keep large source grammar matrices in `test/authoring`.
There is some deliberate overlap: authoring tests own source rules and public
dependency inspection; property graph tests add effect order and process
cleanup. Do not copy each new case into both suites.

## Read The Report In CI

The test helper replaces the old report with `status: "incomplete"` before test
files load. A finished report has `status: "finished"` and an `outcome` of
`passed`, `failed`, or `no_evidence`. A failure keeps passed evidence from other
tests, but it does not grant case evidence to the failed test. Unknown contract
and invalid case IDs include failed and excluded declarations. Missing evidence
is expected for a selected file or directory.

The report includes UTC start/end times and ExUnit include/exclude filters.
Git revision and dirty state are `null` when Git metadata is unavailable, or
when the source folder is inside another repository. A dirty flag does not
identify the tested diff. Save the diff or test a clean CI revision when exact
source reproduction matters.

Use the Mix exit status as the run result. A formatter cannot report a build
failure that occurs before the test helper loads, or a later warnings-as-errors
failure. In CI, delete the previous report before invoking Mix. Require a new
finished report, a successful Mix exit, no artifact errors or unknown/invalid IDs, and the evidence
expected for that selection. Save the report and test log together. Use separate
build roots for concurrent jobs; one report path belongs to one run.

## Replay

StreamData reports an ExUnit seed and reduced values. Rerun the owning file with
`--only property --seed SEED`. Keep real reduced failures as fixed regressions.

The fourteen StreamData fuzz cases save reduced JSON inputs under
`_build/test/property-counterexamples/<property-id>/`. A custom `MIX_BUILD_PATH`
changes this root. They replay saved inputs before generating new inputs, even
with another seed or variant. Fixed examples run first. A replay failure stops
that property and is not shrunk again. A missing or malformed replay file fails
before generation and names the file in the error. The record includes input, contract IDs, seed, framework
and runtime versions, and available source metadata. Keep the tested diff when
the source is dirty. A seed alone is not stable across generator changes.

After a new failure is reduced, the experiment runs that input once more. It
records whether the exception kind and message match. A failure that does not
repeat still fails the test. This repeat check does not prove deterministic
scheduler replay. Each attempt gets fresh runtime resources and cleanup.

To retain a real failure in Git, review the JSON record and copy it to
`test/property/corpus/<property-id>/<name>.json`. The owning property loads these
files automatically. The variants share this corpus. Writes use unique temporary
files and an atomic rename, so concurrent variants cannot expose partial records.
Remove obsolete local records only after inspection. The
fixed support tests use isolated temporary roots and deliberately test failure
output; their printed probe failures are expected when the support tests pass.

The short PropCheck property stores command failures in `_build/propcheck-property.ctx`. A custom
`MIX_BUILD_PATH` puts the store in that build root. ExUnit's seed does not set
PropEr's random seed; the saved command sequence is the exact replay input.

```sh
MIX_ENV=test mix propcheck.inspect
mix test test/property/execution --include property --only failing_prop
MIX_ENV=test mix propcheck.clean
```

Inspect or copy a saved failure before a selected PropCheck run. PropCheck
loads and clears its store at application startup and stores a failure again
when its property runs. Runs that do not select properties leave that store
alone. Runtime-matrix jobs use separate build roots and counterexample stores.

The `revision_histories` fuzz case uses a separate store:
`_build/test/property-counterexamples/revision_histories/*.term`. It writes native
PropCheck counterexamples with Erlang term encoding. The run record links the
file to its contract IDs and source/runtime metadata. Native command generation
and shrinking stay with PropCheck. This case does not open or clear the short
suite's store. It replays every saved term before new generation and checks a
newly reduced failure once more. A failed repeat still fails the test.

Replay accepts only this model's known symbolic commands and initial state.
PIDs, monitors, and execution tokens are made during execution and are not saved.
Rerun `mix test test/property/execution/revision_fuzz_test.exs --only fuzz` to
replay. ExUnit's seed does not set PropEr's random seed. Keep the saved term for
exact command replay; `mix propcheck.inspect` applies only to the short store.
Promote a useful reduced command sequence to a fixed history in the owning test.

## Loading And Cleanup

Support files are explicitly required and excluded from Mix test discovery.
They are not in `elixirc_paths`. PropCheck remains test-only with
`runtime: false`; no property framework is a Jido runtime application dependency.

Execution samples own a private Task Supervisor and unique message reference.
Controlled callbacks announce readiness, wait for release, and are monitored.
Monitor barriers confirm worker/controller exit before absence assertions.
A supervisor can briefly retain a dead child's entry. Check that no live child
remains instead of requiring an empty list at that instant. Supervisors, probes,
telemetry handlers, and dynamic DSL modules
are removed in `after`, including failed examples and shrink attempts.

The revision model completes its latest paused execution, deletes its own
process-dictionary key, and drains only its reference's messages. Serial DSL
properties reuse fixed module names and remove generated modules. No global
process name, external service, sleep, or arbitrary-death cleanup guarantee is
used. Timeouts are tested with blocked callbacks, not elapsed-time comparisons.

## Maintenance

A public behavior change must update the register, required cases, and tests
in one change. Keep run results in generated CI artifacts. Do not maintain a
second checked-in results log. Property tags and case counts do not establish
complete API or branch coverage; the register names remaining gaps.

Further work can expand the bounded component grammars and add independent
stored-format oracles for more component kinds. The current fuzz cases include
State schema failures and supplied absolute-deadline equality across mixed
continuations. Deadline metadata does not add a controller timer; blocked-work
checks use an explicit finite `timeout:`. Exact validator diagnostics, descriptor
callback failures, full telemetry field matrices, supervisor routes, trapped-exit
cancellation, and completion/cancellation races retain focused fixed tests.
No mutation score is available. Add deliberate fault checks when a change needs
measured fault-detection evidence.

Fresh PropCheck/PropEr dependency builds can emit their own compiler warnings.
Do not suppress them. Keep package/test warnings-as-errors checks separate
from dependency diagnostics. Use isolated Mix build roots for supported runtime
checks so BEAM files from one OTP release do not enter another runtime's run.
