# Covenant contract checks

The contract files under `test/contracts` define the requirements checked by
the tagged tests. See the stable
[public register](../../guides/public-contracts.md).

Mix fetches Covenant 0.2 from Hex. No local Covenant checkout is required:

```sh
export ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1"
mix deps.get
mix test.contracts
```

The Hex dependency in `mix.exs` includes macro and protocol mutation support.
It is used in development and tests only. `config/config.exs` sets
`contracts_dir: "test/contracts"`.

Static checks do not load Mix configuration. Supply the paths explicitly:

```sh
mix covenant.check --static --contracts test/contracts --test-path 'test/**/*_test.exs'
```

The components cover Actions, errors, Instructions, Action execution boundaries,
Output, shared validation, inline Actions, Expressions, Flow definitions,
storage, and immediate and managed execution.
The configured test path selects tests across the package.
`mix test.contracts` includes properties with seed zero and keeps fuzz and
other optional suites excluded. Normal tests with obligation tags still run
in their usual suites. Covenant reports and mutation checks run only when
requested; default CI and release preflight do not run them.

The active inventory has **48 focused obligations in 15 public promise groups**.
The [contract review](../../guides/public-api-contract-review.md#active-covenant-mapping)
maps the groups to facets. The register points to shared evidence; it does not
create a second obligation for each entry. Tests for private helpers and
layouts remain useful ordinary checks and do not define new public APIs.

The command fails when an active obligation lacks passing tagged evidence or
when tagged tests fail. A green coverage count is a minimum evidence check,
not proof of complete matrix or branch coverage. Review the acceptance matrix
and test assertions for each promise. Fresh results are written to
`test/contracts/coverage.json`.

```sh
mix covenant.mutate jido_action.action --macros \
  --recompile test/support/fixtures/action/definitions.ex --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.errors --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.instruction --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.output --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.validation --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.boundary --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.inline --macros \
  --recompile test/support/fixtures/action/inline_host.ex \
  --recompile test/support/fixtures/flow/inline.ex --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.expression --macros --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.flow --module Jido.Flow.GraphValidation --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.codec --module Jido.Flow.Codec.Reader --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.execution --module Jido.Exec.Node.Choice --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000
mix covenant.mutate jido_action.inline --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000 \
  --out tmp/covenant/mutate/jido_action.inline/runtime_kill_matrix.json
mix covenant.mutate jido_action.expression --seed 0 --jobs 1 --max-mutants-per-worker 50 --max-runtime 4500000 \
  --out tmp/covenant/mutate/jido_action.expression/runtime_kill_matrix.json
```

Run one job at a time. Each mutation command has a 75-minute deadline. A worker
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

Each test names the obligations it checks. IDs use `<component>.I<n>`. The
public module documentation is the API source; obligation files connect those
requirements to their tests. The `.survivors.yml` files record reviewed
mutation survivors and their reasons. They apply to the source and mutation
profile that produced them; changed source can require a fresh review. No
mutation run is implied by the current contract coverage result.

Fresh coverage is written to `test/contracts/coverage.json`. Matrices are under
`tmp/covenant/mutate/<component>/`.
`mix test.contracts --no-run` reads saved results and does not check whether
they match the current source. Use the full check command above for acceptance.

Mutation results cover the declared modules and supported operators. Default
mode skips macro bodies, quotes and struct declarations. Macro mode includes
provider macros and their quoted output. It does not include quoted builders
inside ordinary functions. Handwritten protocol functions are supported for
literal protocol/type declarations. Types, guard definitions, aliases and
compiler declarations are outside the operator set.
