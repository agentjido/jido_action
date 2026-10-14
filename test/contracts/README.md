# Covenant contract checks

The contract files under `test/contracts` define the requirements checked by
the tagged tests. See [progress](full-coverage-progress.md) and the stable
[public register](../../guides/public-contracts.md).

Mix fetches the pinned Covenant fork. No local Covenant checkout is required:

```sh
export ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1"
mix deps.get
JIDO_COVENANT_PILOT=1 mix covenant.check
```

The Git dependency in `mix.exs` includes macro and protocol mutation support.
It is used in development and tests only. `config/config.exs` sets
`contracts_dir: "test/contracts"`.

Static checks do not load Mix configuration. Supply the paths explicitly:

```sh
mix covenant.check --static --contracts test/contracts --test-path 'test/**/*_test.exs'
```

The current components are Action metadata/macros, Action errors, Instructions,
Action execution boundaries, Output, shared validation, inline Actions and
Expressions.
The configured test paths select their existing unit and property tests.
`JIDO_COVENANT_PILOT=1` includes properties with seed zero and keeps fuzz and
other opt-in suites excluded. Default test selection is unchanged.

```sh
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.action --macros \
  --recompile test/support/fixtures/action/definitions.ex --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.errors --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.instruction --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.output --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.validation --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.boundary --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.inline --macros \
  --recompile test/support/fixtures/action/inline_host.ex \
  --recompile test/support/fixtures/flow/inline.ex --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.expression --macros --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.inline --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000 \
  --out tmp/covenant/mutate/jido_action.inline/runtime_kill_matrix.json
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.expression --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000 \
  --out tmp/covenant/mutate/jido_action.expression/runtime_kill_matrix.json
```

Run one job at a time. Each mutation command has a 75-minute native deadline.
The local check scripts also use an external process-tree deadline and a shared
lock at `/private/tmp/jido-covenant-local-validation.lock`. Those scripts are
under `tmp/covenant-pilot/`; their status files record process cleanup. A worker
VM handles at most 50 verdicts before it is replaced in the same worker slot.

Covenant recompiles explicit caller sources in order and the selected contract
test files last. It does not discover transitive callers. Mutation workers keep
the original code and restore it after each run. Caller compile failures are
invalid mutations and receive no kill credit.
Run both modes for Inline and Expression. Runtime-only results test runtime
mutations without caller compilation failures. Macro results check provider
expansions and the compiled host boundary. Do not combine their kill totals.

Run supported-runtime package suites in sequence. Their ExUnit fixture paths
are shared even when their build roots differ. Run broad package checks after
the mutation workers stop to avoid CPU contention in the large-data cases.

Each test names the obligations it checks. IDs use `<component>.I<n>` and the
original sixteen pilot IDs remain stable. The public module documentation is
the API source; obligation files are evidence indexes for those promises.

Fresh coverage is written to `test/contracts/coverage.json`. Matrices are under
`tmp/covenant/mutate/<component>/`; local logs are under `tmp/covenant-pilot/`.
`mix covenant.check --no-run` reads saved results and does not check whether
they match the current source. Use the full check command above for acceptance.

Mutation results cover the declared modules and supported operators. Default
mode skips macro bodies, quotes and struct declarations. Macro mode includes
provider macros and their quoted output. It does not include quoted builders
inside ordinary functions. Handwritten protocol functions are supported for
literal protocol/type declarations. Types, guard definitions, aliases and
compiler declarations are outside the operator set.

The earlier measurements are retained as historical evidence in the
[Error](pilot-results.md), [Instruction](instruction-pilot-results.md) and
[Action macro](action-macro-pilot-results.md) pilot reports. Current source and
results belong in the progress report above.
