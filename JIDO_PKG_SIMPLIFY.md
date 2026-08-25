# Jido Action Package Simplification Audit and Next-Pass Plan

Status: Complete on `v3-spike` as of 2026-08-25.

The code implements the fixed data and execution architecture. This pass
corrects the required contract defects, closes the required proof gaps, and
applies all approved A-series recommendations. The full guide rewrite stays
deferred because the guides are known to need a separate content pass. This
pass corrects release-facing names and statements that changed with the
approved API work.

This document replaces stage-wide completion claims with claims that the code
and tests prove. It also defines the next pass. It does not change the Spark
DSL shape, the canonical `%Jido.Flow{}` contract, or Codec document version 1
from `JIDO_FLOW_RUNIC_PLAN.md`.

## Audit rules

The Runic plan is the design authority. This plan can simplify ownership and
delete duplicate paths. It cannot create a new Flow architecture.

Priority has this meaning:

- **P1**: Complete this item before the package has a completion or
  release-ready
  claim.
- **P2**: Complete this item in the next simplification pass, or record a clear
  reason to defer it.
- **P3**: Optional refinement. Do it only when direct evidence shows a clearer
  boundary or stronger proof.

Contract risk has this meaning:

- **High**: The item can change stored data, a public error, a public type, a
  public function, or the native Runic dependency contract.
- **Medium**: The item can change public diagnostics, scheduling proof, or an
  exported but hidden function.
- **Low**: The item changes internal code, tests, or text without a planned
  runtime contract change.

A passing broad check is useful evidence. It does not prove a contract when
the direct assertion is absent.

## Fixed contracts and decisions

- Direct constructor authoring is an official `Jido.Flow` API.
- The public Spark DSL shape does not change.
- `%Jido.Flow{}` is the only canonical Flow authoring value.
- `%Jido.Flow.Compiled{}` contains derived compilation data.
- Authored `after` values stay separate from derived dependencies.
- `Jido.Flow.Codec` and a trusted `Jido.Flow.Registry` own stored Flow data.
- The Codec document version stays at 1.
- Codec decode returns the canonical Flow value through the supported
  constructors. It does not return a second storage model.
- Native Runic Workflow and Runnable values stay visible in the advanced API.
- A Spark `step` or `Builder.step` target can be an Action or a Flow. A
  canonical `Jido.Flow.Step` is Action-only. A Flow target becomes a canonical
  `Jido.Flow.Subflow`. Embedded Choice, Map, Reduce, and Iterate targets stay
  Action-only.
- Every Flow has an explicit `output`. There is no terminal-output inference.
- `Jido.Exec` stays the common normalized and supervised execution API for
  Actions and Flows.
- Direct calls to an Action callback stay a lower-level Action API. The caller
  owns validation and execution policy on that route.
- `Jido.Exec` keeps caller-owned, in-memory, step-wise Flow execution.
- `Jido.Exec.Supervisor` stays the OTP and Jido instance-routing extension
  point.
- A requested `jido:` instance has no silent global fallback.
- `Jido.Exec.run/4` accepts `timeout: milliseconds | :infinity`. The default
  is `:infinity`.
- A finite timeout applies to one complete call. It is not a per-attempt or
  per-runnable timeout.
- `Jido.Exec.start/4` and step-wise operations do not start a timeout clock.
- Caller process exit stops active Exec work. A public asynchronous
  cancellation handle stays deferred.
- Exec performs one execution attempt. It applies caller-supplied `async` and
  `max_concurrency` options. It does not select retry count, backoff, jitter,
  idempotency, or exactly-once policy.
- Action and Flow execution and timeout errors are non-retryable by default.
  A direct `details.retry: true` value is a hint for a higher-level caller.
- An Action error inside a Flow keeps its `Jido.Action.Error` type.
- Map collected errors keep their current portable message shape.
- `Jido.Flow.Builder.value/1` and its reference and condition helpers stay.
- Compiler and Codec file size alone is not a reason to split them.
- File count and line count are audit facts. They are not success measures.
- The 24 packaged guides are part of the release surface. They are not outside
  the release audit.
- The Flow concurrency Registry and DynamicSupervisor stay Exec-global.
  `jido:` selects the Task Supervisor for Action workers, including Action work
  inside a Flow or Subflow.

## Current evidence snapshot

This table is the input snapshot from the ultra review. The final verification
record at the end of this document supersedes it.

| Evidence | Current result |
| --- | --- |
| Branch | `v3-spike` |
| Production source | 54 `.ex` files, 66 explicit module declarations, 12,253 lines |
| Compiled application | 122 modules: 38 public in ExDoc and 84 hidden |
| Tests | 35 `*_test.exs` files; 310 passed and 2 excluded |
| Integration tests | 2 passed |
| Coverage | 93.15 percent with warnings as errors |
| Quality | Doctor, ExDoc, Credo, Dialyzer, format, and compile checks passed |
| Runic | Requirement `~> 0.1.0-alpha.9`; lock `0.1.0-alpha.9` |
| Direct production dependencies | `telemetry`, `zoi`, `runic`, `splode`, and `spark` |
| Package | Hex build passed; 84 files and 728 KiB unpacked: 54 source files, 24 guides, 5 root files, and `hex_metadata.config` |
| Package exclusions | Tests and both design-plan files are not in the package |
| Xref | 54 nodes, 3 compile edges, 69 export edges, 152 runtime edges, 2 cycles |

The compiled public-module set matches the ExDoc module groups. No hidden
module appears as a public ExDoc module. The package content and direct
dependency list match `mix.exs`.

Compared with `HEAD`, the current working tree has two fewer source files and
two fewer explicit module declarations. It has 263 more production source
lines. This is evidence of boundary consolidation. It is not broad size
reduction.

Doctor reports 86.1 percent specification coverage. `.doctor.exs` excludes
`Jido.Flow.Builder` and `Jido.Flow.Condition` because of a parser limit. Its
specification thresholds are zero. Thus, a Doctor pass does not prove that all
public functions have useful type contracts.

The broad checks do not detect all errors. For example, ExDoc accepts an
inline reference to a module that does not exist. The tests also do not prove
all target forms or all native Runic port contracts.

## Boundary ownership

| Boundary | Owner | Input and output | The owner must not do this work |
| --- | --- | --- | --- |
| Action authoring | `Jido.Action` and `Jido.Action.Output` | An Action module and its explicit output envelope | Store Flow graph or process state |
| Invocation data | `Jido.Instruction` | A target, params, context, and caller metadata | Select an adapter, timeout, retry, or runtime policy |
| Flow authoring | `Jido.Flow` and public component constructors | Canonical author data | Store source locations, native Runic data, process state, or derived dependencies |
| Runtime Flow authoring | `Jido.Flow.Builder` | Builder calls to the same canonical Flow value | Create a second Flow model |
| Spark translation | `Jido.Flow.DSL.*` | Spark parser data to the canonical Flow value and a separate source map | Change the public DSL or put source data in author `meta` |
| Executable resolution | `Jido.Executable` | A caller target to `%Jido.Executable{kind, target}` | Store an adapter or run the target |
| Structural validation | Public constructors and `Jido.Flow.Validation` | Author data to valid canonical data | Resolve storage text or schedule work |
| Executable preparation | `Jido.Flow.Validation.prepare_executable/2` through `Jido.Flow.Compiler.prepare/2` | One materialized Flow and a request-scoped child cache | Put the cache in canonical, stored, or public execution data |
| Dependency and identity analysis | `Jido.Flow.Graph` and `Jido.Flow.Identity` | Canonical Flow to derived analysis | Write derived data into authored `after` fields |
| Stored data | `Jido.Flow.Codec` and `Jido.Flow.Registry` | Canonical Flow to or from one closed version-1 JSON document | Infer legacy shapes, create atoms from text, or store runtime data |
| Native compilation | `Jido.Flow.Compiler` | One prepared Flow to `%Jido.Flow.Compiled{}` and native Runic data | Build a second Jido graph or scheduler |
| Flow leaf bridge | `Jido.Flow.Compiler.Target` | Resolved target context and Action result to a Flow-owned boundary result | Resolve the executable again or own Action execution policy |
| Action execution | `Jido.Exec.ActionRunner` | A validated Action call to an Action result or Action error | Return a Flow-owned error |
| Complete execution | `Jido.Exec` and its private adapters | Action or Flow target to one normalized supervised call | Select retry policy or durable orchestration |
| Step-wise execution | Public `Jido.Exec` functions with internal `FlowEngine` and guards | Caller-owned execution state and native Runnable values | Hide support runnables or add a second runnable model |
| Process routing | `Jido.Exec.Supervisor` | `jido:` option to the selected Task Supervisor | Fall back when a requested instance is absent |
| Timeout | `Jido.Exec` | One relative timeout to one monotonic complete-call deadline | Convert it to a retry or per-runnable deadline |
| Retry | Caller or Jido core | Direct retry hint to an external policy decision | Run an automatic retry in Exec |
| Errors | `Jido.Action.Error` and `Jido.Flow.Error` | Domain faults to domain-owned errors | Add a third Exec or Executable error model |
| Telemetry | Exec lifecycle and compiler target boundaries | Stable event names and metadata | Change error ownership or execution results |

This table is a boundary rule. A private helper is valid only when it supports
one owner. It must not become a second owner.

## Code-proven completed work

### Canonical and derived data

- `%Jido.Flow{}` contains only author fields. See `lib/jido_flow.ex:63-85`.
- `%Jido.Flow.Compiled{}` owns the Workflow, source map, identity, and other
  derived data. See `lib/jido_flow/compiled.ex:1-28`.
- Dependency analysis does not write effective dependencies into authored
  `after` values. See `lib/jido_flow.ex:245-257` and
  `test/jido_flow/graph_identity_test.exs:10-42`.
- The Spark lowerer and Builder create the same component types. They derive
  Step or Subflow from the shared executable descriptor.

### Executable resolution and preparation

- `%Jido.Executable{}` contains only `kind` and `target`. See
  `lib/jido_executable.ex:43-56`.
- Exec derives the private adapter from `kind`. See `lib/jido_exec.ex:337-394`.
- One Exec request resolves its final target once. Instruction merge uses
  `normalize_resolved!` and does not start a second resolver. See
  `lib/jido_exec.ex:294-323` and `lib/jido_instruction.ex:85-105`.
- A callback-count test intends to prove one descriptor callback in an
  execution request. It uses timed absence checks, so R10 requires a
  deterministic signal. See
  `test/jido_exec/instruction_execution_test.exs:24-37`.
- Flow execution materializes the exact `flow/0` value and calls one compiler
  preparation path. It does not trust an independent `compiled/0` result. See
  `lib/jido_exec/flow_adapter.ex:54-89` and
  `test/jido_exec/flow_adapter_test.exs:62-188`.
- Executable preparation has one request-scoped cache for nested Flow modules.
  The repeated-child test proves one child materialization in one preparation
  call. See `lib/jido_flow/validation.ex:217-318` and
  `test/jido_exec/flow_adapter_test.exs:178-188`.
- Flow leaf work calls the already validated Action target. It does not run
  executable resolution for each item or iteration. See
  `lib/jido_flow/compiler/target.ex:90-104` and
  `lib/jido_exec/target_runner.ex:8-23`.

### Stored data

- Codec has one explicit root type, document version 1, closed component tags,
  field checks, depth checks, and collection-size checks. See
  `lib/jido_flow/codec.ex:31-127` and `lib/jido_flow/codec.ex:418-831`.
- Registry has typed Action, Flow, schema, and atom identifiers. It has one
  write identifier per trusted value and read-only aliases. See
  `lib/jido_flow/registry.ex:29-45` and
  `lib/jido_flow/registry.ex:86-248`.
- Codec sorts portable map entries and decodes through the canonical Flow
  constructor. Tests cover round trips, wrong versions, unknown kinds, wrong
  Registry kinds, unknown module text, key types, malformed records, and the
  current local limits.
- This evidence does not prove JSON portability. Required item R1 documents a
  case that fails.

### Native Runic compilation and exposure

- Compiler lowers Step, Choice, Iterate, Map, Reduce, FanOut, FanIn, direct
  Map-to-Reduce, Join paths, and nested Workflow boundaries to installed Runic
  constructs. See `lib/jido_flow/compiler.ex:185-520` and
  `lib/jido_flow/compiler.ex:693-876`.
- `Jido.Flow.Compiled.workflow` is a native `Runic.Workflow`.
- `Jido.Exec.ready/1`, `step/2`, and `wave/1` expose native
  `Runic.Workflow.Runnable` values. They do not wrap support runnables in a
  Jido runtime type.
- Compiler and execution tests prove native component types, support runnable
  visibility, nested InputBinding values, full-run and step-wise result
  parity, and direct Map-to-Reduce behavior.
- This evidence does not prove every exact port, cardinality, connection, or
  Join contract. Required item R5 defines that missing proof.

### Action, Flow, and Instruction execution

- Action modules, Flow modules, runtime Flow values, and Instructions use the
  same executable resolver and adapter selection boundary.
- Action and Flow leaves use `Jido.Exec.ActionRunner` for Action execution.
  `Jido.Flow.Compiler.Target` adds only Flow context, telemetry data, and error
  tags.
- Direct Action or Action Instruction calls preserve callback extras. A Flow
  consumes only the Action output or error and discards leaf extras.
- Flow execution validates its input and output at the Flow boundary. Action
  execution validates Action input and output at the Action boundary.
- Instruction params and context use the same merge rule for Action and Flow
  targets. The actual Instruction value also preserves caller metadata, which
  has no execution meaning.

### Timeout, retry, routing, and errors

- Exec converts a finite complete-call timeout to one monotonic deadline. See
  `lib/jido_exec.ex:174-231`.
- The current zero-timeout test asserts no dispatch for one Action module. It
  uses a timed absence check, so R6 and R10 require deterministic proof.
- Step-wise start rejects the complete-call timeout option.
- Exec has no automatic retry loop. Error modules only expose a direct retry
  hint.
- Action and Flow timeout errors stay in their domain. An Action failure in a
  Flow keeps the Action error type.
- `Jido.Exec.Supervisor` resolves a requested Jido Task Supervisor and returns
  an error when the requested instance is absent. Action workers use the
  selected supervisor.
- The current tests prove much of this behavior. They do not prove the full
  target-form matrix. Required item R6 defines the missing proof.

### Compiler and package boundaries

- `Jido.Flow.Compiler.Target` now owns target context, target telemetry data,
  and target error tags. The former target-context and error-tagger source
  files are removed.
- The ExDoc groups name all 38 intended public modules. The other compiled
  modules are hidden.
- The Hex package includes the intended source, guides, and root files. It
  excludes tests and design plans.
- The direct production dependency list has the intended five dependencies.

## Resolution and validation rule

“Once” means once inside one preparation or execution request. It does not
mean once for the life of a value.

| Operation | Current reason for the check | Audit result |
| --- | --- | --- |
| `Instruction.new/1` | Validate caller construction data | Valid construction boundary |
| `Exec.run/4` or `Exec.start/4` | Treat an existing target or Instruction as new request input | Code has one resolver per request; R10 must make callback proof deterministic |
| Flow and component constructors | Validate canonical author data | Valid author boundary |
| `Codec.encode/2` | Treat a raw struct as untrusted storage input | Revalidation is intentional |
| `Codec.decode/2` | Validate untrusted stored data and construct canonical data | Required trust boundary |
| `Flow.compile/2` and Flow execution | Treat raw structs and module callbacks as new compile input | Structural and executable preparation is intentional |
| Flow leaf execution | Run a target that preparation already resolved and validated | A second resolver is absent |
| Spark module compilation | Lowerer resolves a top-level target for Step/Subflow selection, then executable validation resolves it again | Possible duplicate; measure before a change |

Do not remove a check only because the same value was valid at an earlier time.
Raw structs, changed module code, a different Registry, and a new execution
request create new trust boundaries.

The Spark compile-time double resolution is the only observed same-operation
candidate. A change must use compiler-owned temporary data. It must not add an
executable descriptor to `%Jido.Flow{}` or change the DSL. Optional item O1
defines this review.

## Required work and implementation results

### R1 — Reject non-JSON strings at the Codec boundary

- **Status:** Complete.

- **Priority:** P1.
- **Scope:** `Jido.Flow.Data`, `Jido.Flow.Codec`, and Codec tests.
- **Contract risk:** High. Codec promises a JSON-compatible document.
- **Current evidence:** `Data` and Codec accept every binary as a string. A
  Flow with `description: <<255>>` returns `{:ok, document}` from
  `Codec.encode/2`. `Jason.encode(document)` then returns
  `Jason.EncodeError` for invalid byte `0xFF`.
- **Required result:** Accept only valid UTF-8 at every portable string
  position. Do not add a new binary storage type.
- **Proof needed:** Test invalid UTF-8 in a root string, literal value, map key,
  metadata value, and Registry-facing identifier position. Prove
  `Codec.encode -> Jason.encode -> Jason.decode -> Codec.decode` for accepted
  documents.
- **Staged verification:** First run the focused Codec tests. Then run all Flow
  data, Registry, and Codec tests. Finally run unit, integration, coverage,
  quality, documentation, and package checks.

### R2 — Consume one revision for one successful wave

- **Status:** Complete.

- **Priority:** P1.
- **Scope:** `Jido.Exec.FlowEngine`, a focused revision-owner test, and public
  stale-state execution tests.
- **Contract risk:** High. `Jido.Exec` documents revision as an atomic
  step-or-wave guard.
- **Current evidence:** `do_wave/1` applies each Runnable with
  `apply_runnable/2`, and each application increments revision. A read-only
  probe with two ready Steps changed revision from 0 to 2 in one successful
  wave. The current test proves only the one-Runnable step case.
- **Required result:** One successful `step/2` or `wave/1` call consumes one
  execution revision, independent of the number of Runnables in the wave.
- **Proof needed:** In a focused FlowEngine or guard-owner test, start a Flow
  with two ready Runnables and assert a revision delta of 1 after `wave/1`.
  Through the public API, reuse the prior execution value and assert a stale
  error with current revision 1, no second dispatch, and successful continued
  use of the new execution value.
- **Staged verification:** First run the focused revision-owner and public
  stale-state tests. Then run all Exec guard and native execution tests.
  Finally run all release checks.

### R3 — Use one unresolved-Instruction error contract

- **Status:** Complete.

- **Priority:** P1.
- **Scope:** `Jido.Exec` Instruction resolution and Instruction execution
  tests.
- **Contract risk:** High. This changes the public error from one current path.
- **Current evidence:** `Exec.run/4` wraps an unresolved Instruction target in
  `Jido.Action.Error.InvalidInputError`. `Exec.start/4` returns the underlying
  `Jido.Action.Error.ConfigurationError`. The current test fixes only the run
  behavior.
- **Required result:** Follow the fixed Runic plan. A failure before the target
  kind is known uses `Jido.Action.Error.ConfigurationError`. Run and start must
  not create two contracts.
- **Proof needed:** Add a run/start matrix for an Action module, Flow module,
  runtime Flow value, Action Instruction, Flow Instruction, and malformed raw
  Instruction target. Assert the exact owner and subtype.
- **Staged verification:** First run Instruction construction and execution
  tests. Then run all Exec and error tests. Finally run all release checks.
- **Approval rule:** Selecting `InvalidInputError` instead would change the
  fixed Runic plan and needs explicit approval.

### R4 — Correct false public documentation

- **Status:** Complete for the release-facing API changes in this pass. A full
  guide content rewrite is deferred by explicit user direction.

- **Priority:** P1.
- **Scope:** Packaged guides, README, Registry and Condition documentation,
  and the public API map.
- **Contract risk:** Low. This required item corrects text only. Approval item
  A3 owns any function visibility change.
- **Current evidence:** `guides/flows.md:48` names the nonexistent
  `Jido.Flow.SourceMap`; the real type is
  `Jido.Flow.Compiled.source_map()`. `Jido.Flow.Condition.validate/2` says it
  builds or raises, but it returns an ok/error tuple. `Condition.new!/2` is
  hidden, but a test name calls it exposed. `guides/flows.md` leads with raw
  Flow and Step structs although constructors are the supported authoring
  boundary. The README calls the advanced public `Jido.Executable` descriptor
  internal. `AGENTS.md:20` and `AGENTS.md:140` describe Instruction as
  Action-only and omit metadata, but current code supports Action and Flow
  targets and publishes metadata.
  `Jido.Flow.Registry.identifier/3` supports Flow values, but its text omits
  them. Only 11 of 38 public modules contain a code example.
- **Required result:** Correct false names and behavior statements. Do not call
  a hidden helper exposed. Mark raw structs as shape-only examples or replace
  them with constructor calls. Describe `Jido.Executable` as an advanced
  public descriptor and its adapters as internal. Align the contributor rules
  with the actual Instruction target and field contract. Add examples only
  where they support a developer task. Do not claim that every public module
  has an example.
- **Proof needed:** Review the 38 public module pages and all 24 packaged
  guides. Scan for stale module names, except intentional old names in the v3
  migration guide. Check each documented return and raising statement against
  its spec and code.
- **Staged verification:** First run focused documentation and stale-symbol
  scans. Then run ExDoc and Doctor with the documented exclusions. Finally
  inspect the built package documentation set.

### R5 — Add exact proof for the locked native Runic contract

- **Status:** Complete.

- **Priority:** P1.
- **Scope:** Native compiler tests and native step-wise execution tests for
  locked Runic `0.1.0-alpha.9`.
- **Contract risk:** High because native Runic types are public and compiler
  code constructs alpha-version structs directly.
- **Current evidence:** Tests prove component types and some support
  Runnables. They do not assert the exact Step, Map, Reduce, and Subflow port
  names, cardinality, and named connections. No checked-in test asserts a
  native Join Runnable. The Subflow test asserts only one wildcard input and
  output port.
- **Required result:** Prove the exact native graph contract that Jido uses for
  the locked Runic version. Keep native support Runnables visible.
- **Proof needed:** Assert exact ports, cardinality, connections, FanOut,
  FanIn, direct Map-to-Reduce, nested Workflow boundaries, InputBinding, Join,
  and full-run versus step-wise result parity.
- **Staged verification:** First run focused native compiler tests. Then run
  native execution and Subflow tests. Finally run all release checks and the
  unpacked package check.

### R6 — Complete timeout and instance-routing target-form proof

- **Status:** Complete.

- **Priority:** P1.
- **Scope:** Public Exec process, timeout, and Jido routing tests. Production
  code changes only if the matrix finds a defect.
- **Contract risk:** High if the matrix finds a behavior defect. Test additions
  alone have low contract risk.
- **Current evidence:** Zero-timeout proof covers one Action module. Finite
  Flow timeout proof covers a runtime Flow value and an Instruction that holds
  that value. Jido routing proof covers an Action module, Action Instruction,
  and runtime Flow. It does not cover all Flow module, Flow Instruction, and
  Subflow paths.
- **Required result:** Prove the same routing, no-fallback, timeout owner,
  no-dispatch, and cleanup rules for each applicable target form.
- **Proof needed:** Use a small matrix for Action module, Action Instruction,
  Flow value, Flow module, Flow Instruction, and a parent Flow that contains a
  Subflow component. For the parent Flow, cover nested child materialization
  and routed Action work. Assert worker process ownership, zero-timeout
  dispatch count, finite-timeout owner, caller-death cleanup,
  concurrency-permit cleanup, and no retry.
- **Staged verification:** First run targeted process-effect tests. Then run
  all Action process, runtime policy, Subflow, and Exec tests. Finally run the
  full release checks.

### R7 — Validate public source-map input

- **Status:** Complete.

- **Priority:** P2.
- **Scope:** `Flow.compile/2`, compile-option parsing, root and nested Flow
  module source-map callbacks, and diagnostic tests.
- **Contract risk:** Medium. The change tightens a public diagnostic input and
  changes malformed-input errors.
- **Current evidence:** `%Jido.Flow.Compiled{}` defines paths and location
  maps, but Compiler accepts any map. The root callback checks only
  `is_map/1`, and the child callback does not validate entries. A probe can put
  PID keys and PID location data in a public Compiled source map. A non-map,
  non-list option can become an empty source map. Unknown keyword options are
  ignored, and a non-keyword list can fail through `Keyword.get/3`.
- **Required result:** Accept only the documented source-map path and location
  shapes. Return a stable Flow validation error for bad root or child data.
- **Proof needed:** Test malformed root paths, locations, nested child
  callbacks, non-map options, non-keyword lists, and unknown keyword keys.
  Prove that valid Spark source locations still stay separate from author
  `meta`. Approval item A7 records the strict unknown-option behavior.
- **Staged verification:** First run source-map and compiler tests. Then run
  Spark, nested Flow, and Exec Flow-adapter tests. Finally run all release
  checks.

### R8 — Inventory unused hidden exported functions

- **Status:** Complete. The approved exports are removed or private.

- **Priority:** P2.
- **Scope:** Hidden delegates and exported helpers that only their defining
  module calls.
- **Contract risk:** Low. This required item prepares evidence. Approval item
  A6 owns changes to the BEAM export set.
- **Current evidence:** `Jido.Flow.canonical_components/1` is a hidden delegate
  with no production caller. Production code calls
  `Jido.Flow.Graph.canonical_components/1` directly. Its only outside caller
  is a test. `Jido.Executable.validate_action_compatible_callbacks/1` is
  exported but used only in its defining module.
- **Required result:** List each unused hidden export, its intended owner, its
  current callers, and the public or internal test that can replace a direct
  helper test. Prepare the export diff for A6.
- **Proof needed:** Use xref and text search to prove no production caller.
  Prove canonical order through `explain/1`, semantic identity, or a focused
  Graph owner test. Prove executable validation through the public Executable
  boundary.
- **Staged verification:** First run Flow facade, Graph, and Executable tests.
  Then run xref and API inventory checks. After A6 approval, run the focused
  tests, inspect package exports, and run all release checks.

### R9 — Use one `max_concurrency` default

- **Status:** Complete.

- **Priority:** P2.
- **Scope:** `Jido.Exec.Options` and option tests.
- **Contract risk:** Low if stored behavior stays
  `System.schedulers_online/0`.
- **Current evidence:** Validation reads a missing option as `1`, while the
  normalized option stores `System.schedulers_online/0`. The public stored
  default is correct, but the implementation has two sources.
- **Required result:** Derive validation and stored options from one local
  default value. Do not change the documented behavior.
- **Proof needed:** Assert the default, explicit positive values, and invalid
  values through the public Exec boundary.
- **Staged verification:** First run option tests. Then run async Flow and
  concurrency tests. Finally run all release checks.

### R10 — Make policy tests deterministic and keep private state local

- **Status:** Complete for tests. The test suite has no `Process.sleep/1`,
  timed `refute_receive`, or polling helper.

- **Priority:** P1.
- **Scope:** Concurrency limiter, runtime policy, Instruction, and public Exec
  tests.
- **Contract risk:** Low. The planned change is test-only.
- **Current evidence:** Tests use `Process.sleep/1`, short
  `refute_receive` windows, and polling time delays instead of synchronization
  signals. This conflicts with the fixed Runic test rule. Public policy tests
  name `Jido.Exec.ConcurrencyLimiter` and bind internal
  `Execution` fields. A compiler-owner test also calls `Jido.Exec.run/3`.
- **Required result:** Use messages, monitors, barriers, and process effects.
  Keep direct private-state checks only in the focused internal owner test.
  Keep compiler graph proof in compiler tests and public execution proof in
  Exec tests.
- **Proof needed:** Repeat the focused tests over many seeds with no sleeps as
  ordering controls. Assert public status, result, errors, and process effects.
- **Staged verification:** First run each changed file over several seeds.
  Then run all Exec and compiler tests. Finally run all release checks.

### R11 — Prove useful public documentation and type contracts

- **Status:** Complete. Doctor enforces 85 percent minimum specification
  coverage for modules that it can parse. ExDoc checks Builder and Condition.

- **Priority:** P2.
- **Scope:** The 38 public modules, ExDoc groups, `.doctor.exs`, and public
  function specs.
- **Contract risk:** Low. Approval items A3 and A6 own any function hiding.
- **Current evidence:** Public and hidden module classification is exact, but
  example coverage is limited. Builder and Choice have public functions with
  incomplete spec coverage. Doctor excludes Builder and Condition and uses
  zero spec thresholds.
- **Required result:** Define a useful rule for examples and specs by developer
  task. Record tool exclusions. Do not add examples to generated error
  subtypes only to increase a count.
- **Proof needed:** Compare the ExDoc module set with the API levels and
  developer task map. Add focused specs and examples where a developer must
  call the function directly.
- **Staged verification:** First run spec and documentation checks for changed
  modules. Then run Doctor and ExDoc. Finally inspect the public pages in the
  built package.

### R12 — Complete Instruction and target-form telemetry proof

- **Status:** Complete.

- **Priority:** P2.
- **Scope:** Exec telemetry tests.
- **Contract risk:** Medium. Event names and metadata are integration
  contracts.
- **Current evidence:** Current tests cover Flow, component, target, and
  collection events. They do not prove the outer lifecycle sequence for an
  Action module, Action Instruction, Flow value, Flow module, and Flow
  Instruction. Exec creates an outer Instruction telemetry start/stop event
  pair for both Action and Flow Instructions.
- **Required result:** State and test the intended event sequence and metadata
  for every target form. Do not add a second telemetry owner.
- **Proof needed:** Assert event order, execution ID, kind, name, result class,
  and error metadata for the target-form matrix.
- **Staged verification:** First run telemetry tests. Then run Instruction and
  Exec tests. Finally run all release checks.

## Optional refinements

### O1 — Measure Spark compile-time duplicate resolution

- **Status:** Deferred. No runtime defect is present. A cache would add
  compiler-owned state before a measured benefit exists.

- **Priority:** P3.
- **Scope:** `Jido.Flow.DSL.Lowerer`, module compilation, and executable
  preparation.
- **Contract risk:** Medium because source-aware errors and target-kind rules
  must stay exact.
- **Current evidence:** The lowerer resolves each top-level target to select
  Step or Subflow. Module compilation then runs executable validation, which
  resolves targets again.
- **Proof needed:** Count descriptor callbacks for one module compile. Identify
  whether both calls can observe different module state. Prove source-aware
  errors and nested materialization before any change.
- **Staged verification:** Add a measurement test, review a compiler-owned
  temporary cache, run Spark and compiler tests, then run all release checks.
- **Constraint:** Do not put a descriptor in canonical Flow data.

### O2 — Add transitive and sibling identity proof

- **Status:** Deferred. This is useful additional proof, but it does not close
  a current contract defect.

- **Priority:** P3.
- **Scope:** Native compiler identity tests.
- **Contract risk:** Low.
- **Current evidence:** Code propagates sorted child digests. Tests change a
  direct child, but not a grandchild. Sibling tests prove names, hashes, and
  results, but not every public lookup or hook path.
- **Proof needed:** Change a grandchild and assert the root digest changes. Add
  sibling lookup proof only for inspection contracts that stay public.
- **Staged verification:** Run identity and native compiler tests, then the full
  compiler and Exec suites, and finally all release checks.

### O3 — Review one-caller modules and xref cycles

- **Status:** Reviewed. No file merge has a clear ownership benefit. File
  count is not a simplification target.

- **Priority:** P3.
- **Scope:** Internal module graph only.
- **Contract risk:** Low.
- **Current evidence:** Xref reports two cycles. The largest files are Compiler
  and Codec, but size is not proof of a bad boundary.
- **Proof needed:** Name the responsibility that a merge or deletion removes.
  Compare dependencies before and after. Do not set a source-file target.
- **Staged verification:** Run xref, focused owner tests, and all release
  checks after an evidence-based change.

### O4 — Clarify small guide and test terms

- **Status:** Complete.

- **Priority:** P3.
- **Scope:** Packaged guides and public test names.
- **Contract risk:** Low.
- **Current evidence:** `guides/testing.md` uses “Iterator body” where the
  public component is Iterate. `usage-rules.md` can state the stale-execution
  side-effect case more exactly. `guides/configuration.md` says there are
  exactly two Flow policy options, but it later documents `jido:` and
  complete-call `timeout:`. The first two are scheduling options.
- **Proof needed:** Manual term scan against the public API. Keep removed names
  in `guides/v3-migration.md` when they explain migration.
- **Staged verification:** Run the focused term scan, ExDoc, and link checks.
  Then inspect the package and run all release checks.

### O5 — Review duplicate output-shape normalization

- **Status:** Reviewed and not merged. Action and Flow have different error
  owners and different extra-value rules. A shared helper would make that
  boundary less clear.

- **Priority:** P3.
- **Scope:** `Jido.Exec.ActionRunner`, `Jido.Exec.FlowAdapter`, and
  `Jido.Action.Validation`.
- **Contract risk:** Medium because Action and Flow must keep different error
  owners and extras behavior.
- **Current evidence:** ActionRunner and FlowAdapter contain similar result and
  output-shape checks. ActionRunner returns Action errors and preserves direct
  callback extras. FlowAdapter returns Flow boundary errors and Flow execution
  discards leaf extras.
- **Proof needed:** Make a parity table for valid map output, explicit Output
  envelopes, malformed validation returns, invalid output, callback errors,
  and extras. Identify a pure shared check only if error construction stays in
  the domain owner.
- **Staged verification:** First run Action and Flow output-validation tests.
  If evidence supports a shared pure helper, run both subsystem suites and then
  all release checks.

## Approved API decisions

The user approved all recommendations in this section on 2026-08-25.

### A1 — Remove `Instruction.metadata`

- **Decision:** Keep `Instruction.metadata` as caller data. Do not use it for
  runtime policy.

- **Priority:** P2.
- **Decision gate:** Only removal needs approval. Keeping the current field
  needs no code change.
- **Scope:** Public Instruction struct, constructors, guides, usage rules, and
  tests.
- **Contract risk:** High.
- **Current evidence:** Code, tests, and guides publish `metadata`. It is
  caller data with no execution meaning. The prior simplification draft
  omitted it from the boundary text. This audit now includes it.
  `AGENTS.md:140` still omits it.
- **Recommendation:** Keep `metadata`. Do not use it for timeout, retry,
  routing, or execution policy. Correct `AGENTS.md` in an approved later pass.
- **Proof needed if removed:** Public API diff, migration text, constructor and
  merge updates, and confirmation from Jido core consumers.
- **Staged verification:** Record the decision, run Instruction tests and
  documentation checks, then run all release checks.

### A2 — Reduce generated Flow module wrappers

- **Decision:** Remove the six redundant wrappers. Keep `flow/0`,
  `compiled/0`, the executable descriptor, Action-compatible callbacks, and
  the Spark DSL.

- **Priority:** P2.
- **Decision gate:** Record approval before a generated public function is
  removed.
- **Scope:** Generated Flow modules, `guides/flow-modules.md`, and public API
  tests.
- **Contract risk:** High. These are documented generated functions.
- **Current evidence:** Generated modules expose `to_map/0`, `validate/0`,
  `validate_executable/0`, `dependencies/0`, `explain/0`, and
  `semantic_identity/0`. Each delegates to a public `Jido.Flow` function on
  `flow/0`. The fixed Runic generated callback list does not require these six
  wrappers.
- **Recommendation:** Remove the six redundant wrappers after approval. Keep
  `__jido_executable__/0`, `flow/0`, `compiled/0`, `run/2`, schemas,
  validators, and the unchanged Spark DSL.
- **Proof needed:** Search external consumers, publish an API diff, update the
  guide, and prove the direct `Jido.Flow.*(Module.flow())` replacements.
- **Staged verification:** Record approval, run Flow module and Spark tests,
  run ExDoc, inspect the package API, then run all release checks.

### A3 — Classify overlapping Flow inspection and validation functions

- **Decision:** Keep both Flow inspection forms. Classify Data validation as
  advanced portable-data API and Condition validation as authoring API. Keep
  `Condition.new!/2` hidden.

- **Priority:** P2.
- **Decision gate:** Record approval before a published function is hidden or
  removed.
- **Scope:** `Jido.Flow.to_map/1`, `Jido.Flow.explain/1`,
  `Jido.Flow.Data.validate/1`, `Jido.Flow.Data.validate_object/1`, and
  `Jido.Flow.Condition.validate/2` and `new!/2`.
- **Contract risk:** High.
- **Current evidence:** `to_map/1` is an author-order inspection map.
  `explain/1` is a versioned derived inspection map. Codec is the only storage
  map. Data and Condition are classified as type support, but they also expose
  documented validation functions. `Condition.new!/2` is callable but hidden;
  public combinators use it internally.
- **Recommendation:** Keep both Flow inspection functions for this release and
  name their different contracts in the developer task map. Classify Data
  validation as an advanced portable-data API. Treat Condition validation as
  an authoring helper unless consumer evidence supports hiding it. Keep
  `Condition.new!/2` hidden and use public `new/2` or the combinators unless an
  approved constructor policy requires publication.
- **Proof needed for deletion or hiding:** External usage search, API diff,
  migration text, direct and generated Flow tests, and documentation review.
- **Staged verification:** Record the API decision, run data and Flow facade
  tests, run ExDoc and package inspection, then run all release checks.

### A4 — Select the supported Runic version policy

- **Decision:** Pin Runic to exactly `0.1.0-alpha.9`. Repeat the native
  contract proof before a version change.

- **Priority:** P1.
- **Decision gate:** Record the supported-version policy before a Runic update
  or a release-ready claim.
- **Scope:** Mix requirement, lock policy, compatibility tests, and package
  metadata.
- **Contract risk:** High.
- **Current evidence:** The Mix requirement accepts later prereleases and
  stable `0.1.x` versions below `0.2.0`, but the current proof covers only
  `0.1.0-alpha.9`. Compiler code constructs native alpha structs and reads
  fields such as `FanIn.map`. Public APIs expose native Runic types.
- **Recommendation:** Either narrow the requirement to the tested version or
  add a clean dependency and native contract matrix for every accepted
  version. Repeat R5 before each Runic update.
- **Proof needed:** Clean dependency resolution, exact native graph tests,
  native execution tests, and package build for each supported version.
- **Staged verification:** Record the policy, test each supported lock, run the
  full compiler and Exec suites, then run all release checks.

### A5 — Add a total Codec decode work limit

- **Decision:** Enforce a 100,000-node total decode budget in Codec document
  version 1, in addition to local depth and collection limits.

- **Priority:** P2.
- **Decision gate:** Record approval before version 1 rejects a document only
  because of a new total-work limit.
- **Scope:** Untrusted Codec documents and resource-limit tests.
- **Contract risk:** High. A new total limit rejects some documents that
  version 1 currently accepts.
- **Current evidence:** Depth and per-collection limits are local. A document
  can contain many permitted collections and exceed the intended total work by
  a large factor.
- **Recommendation:** Measure representative supported documents and malformed
  documents designed to use excessive work before a total node or work limit
  is selected.
- **Proof needed:** A total-budget test, a documented limit, stable limit
  errors, and accepted-document compatibility tests.
- **Staged verification:** Record approval and the limit, run Codec resource
  tests, run JSON byte round trips, then run all release checks.

### A6 — Remove unused hidden exports

- **Decision:** Remove or make private the listed unused hidden exports. Tests
  use the public owner boundary.

- **Priority:** P2.
- **Decision gate:** Record the package policy for callable `@doc false`
  functions before the BEAM export set changes.
- **Scope:** `Jido.Flow.canonical_components/1`,
  `Jido.Executable.validate_action_compatible_callbacks/1`,
  `Jido.Action.new/0,1`, `Jido.Instruction.validate_executable_target/2`, and
  `Jido.Flow.Registry.valid_identifier?/1`.
- **Contract risk:** Medium because these functions are callable even though
  their docs are hidden.
- **Current evidence:** R8 records the hidden Flow delegate and Executable
  helper. Action runtime constructors always return an error. Instruction
  construction calls `Jido.Executable.resolve/1` directly and does not parse
  its declared Zoi refine. Registry uses its identifier helper internally. No
  production owner outside these modules needs the exports.
- **Recommendation:** Delete or privatize them only after the package export
  policy for `@doc false` functions is explicit.
- **Proof needed:** Xref, external usage search, API diff, replacement boundary
  tests, and a decision about the unused Instruction schema refine.
- **Staged verification:** Record approval, run focused data tests and xref,
  inspect package exports, then run all release checks.

### A7 — Tighten `Flow.compile/2` option parsing

- **Decision:** Keep `source_map:` as the only compile option. Reject unknown
  options and malformed option or source-map data with stable Flow errors.

- **Priority:** P2.
- **Decision gate:** Record approval before currently ignored unknown options
  become errors.
- **Scope:** Public compile options, diagnostics, and migration text.
- **Contract risk:** Medium.
- **Current evidence:** Compiler accepts a source-map map or keyword list. It
  ignores unknown keyword keys, converts some other terms to an empty map, and
  can fail indirectly on a non-keyword list.
- **Recommendation:** Keep `source_map:` as the only documented option. Return
  one stable validation error for malformed option containers. Decide
  explicitly whether unknown keyword keys stay ignored or become errors.
- **Proof needed:** An option-form matrix, an API compatibility review, and
  stable diagnostic assertions.
- **Staged verification:** Record the decision, run compiler and source-map
  tests, run Spark and nested Flow tests, then run all release checks.

## Public API levels

### Core API

- `Jido.Action`
- `Jido.Action.Output`
- `Jido.Instruction`
- `Jido.Flow`
- `Jido.Flow.Builder`
- `Jido.Flow.Codec`
- `Jido.Flow.Registry`
- `Jido.Exec`

### Authoring data API

- `Jido.Flow.Step`
- `Jido.Flow.Subflow`
- `Jido.Flow.Choice`
- `Jido.Flow.Choice.Option`
- `Jido.Flow.Choice.Fallback`
- `Jido.Flow.Map`
- `Jido.Flow.Reduce`
- `Jido.Flow.Iterate`
- `Jido.Flow.Iterate.State`
- `Jido.Flow.Condition`
- `Jido.Flow.Ref`
- The public types in `Jido.Flow.Component`, `Jido.Flow.Data`, and
  `Jido.Flow.Expression` that describe canonical portable data

### Advanced API

- `Jido.Executable`
- `Jido.Flow.Compiled`
- `Jido.Exec.Execution`
- `Jido.Exec.Supervisor`
- `Jido.Action.Error` and its public error types
- `Jido.Flow.Error` and its public error types
- Native Runic Workflow and Runnable values returned by public functions

### Advanced portable-data validation API

- `Jido.Flow.Data.validate/1`
- `Jido.Flow.Data.validate_object/1`

These functions validate data that the canonical constructors and Codec also
check. They stay public for hosts that must validate portable data before they
construct a complete Flow.

`Jido.Flow.Condition.validate/2` is an authoring-data API. It validates one
condition for a reference scope. `Jido.Flow.Condition.new!/2` stays hidden.

### Internal implementation

All modules below these namespaces are internal unless a list above names
them:

- `Jido.Action.Validation`
- `Jido.Flow.Compiler.*`
- `Jido.Flow.DSL.*`
- `Jido.Flow.Graph`
- `Jido.Flow.Identity`
- `Jido.Flow.Validation`
- `Jido.Exec.*Adapter`
- `Jido.Exec.*Runner`
- `Jido.Exec.FlowEngine`
- `Jido.Exec.Options`
- `Jido.Exec.ExecutionGuard`
- `Jido.Exec.ConcurrencyLimiter`
- `Jido.Exec.CollectionTelemetry`

`Jido.Executable` is advanced public API. Its private adapters are internal.
`Jido.Exec.Execution` is an advanced state value, but its fields are internal
implementation data. Public tests and application code must use the public
Exec functions unless a focused internal owner test must inspect a field.

## Developer task map

| Developer task | Supported API | Boundary note |
| --- | --- | --- |
| Define an executable leaf | `use Jido.Action` | Module authoring API |
| Call an Action callback directly | Action validation functions and `run/2` | Lower-level route; caller owns validation and policy |
| Define explicit non-map Action output | `Jido.Action.Output` | Action-owned success envelope |
| Describe one call | `Jido.Instruction.new/1` or `new!/1` | Target, params, context, and caller metadata |
| Run one normalized Action or Flow call | `Jido.Exec.run/4` | Common supervision, routing, timeout, validation, and error boundary |
| Define a static Flow | `use Jido.Flow` | Keep the Spark DSL shape unchanged |
| Get canonical data from a Flow module | `Module.flow/0` | Materialize once per operation |
| Build a runtime Flow | `Jido.Flow.Builder` | Produces `%Jido.Flow{}` |
| Construct canonical Flow data | `Jido.Flow.new/1` and component constructors | Supported direct author boundary |
| Construct references and conditions | `Jido.Flow.Ref` constructors, `Jido.Flow.Condition.new/2`, and public condition combinators | Data-only authoring grammar |
| Check author structure | `Jido.Flow.validate/1` | Does not replace executable preparation |
| Check executable targets | `Jido.Flow.validate_executable/1` | Resolves Action and Subflow targets |
| Resolve or check one target | `Jido.Executable.resolve/1` and `validate/1` | Advanced descriptor API; adapters stay internal |
| Validate portable Flow data | `Jido.Flow.Data.validate/1` and `validate_object/1` | Advanced portable-data API |
| Validate one condition in a scope | `Jido.Flow.Condition.validate/2` | Authoring-data API |
| Inspect author order | `Jido.Flow.to_map/1` | Inspection only; not storage |
| Inspect dependencies and identity | `dependencies/1`, `explain/1`, and `semantic_identity/1` | Derived inspection data |
| Store or load a Flow | `Jido.Flow.Codec` with a trusted Registry | Only supported stored-map contract |
| Compile and inspect native data | `Jido.Flow.compile/2` and `Jido.Flow.Compiled` | Derived native Runic data |
| Control Flow execution | `start`, `ready`, `status`, `step`, `wave`, `continue`, and `result` | Caller-owned state and native Runnables |
| Limit one complete call | `Jido.Exec.run/4` with `timeout:` | One complete-call deadline |
| Route work through a Jido instance | `jido:` and `Jido.Exec.Supervisor` | Missing requested instance is an error |
| Handle failures | `Jido.Action.Error` and `Jido.Flow.Error` | Keep the direct domain owner |
| Select retry policy | Caller or Jido core reads a direct retry hint | Exec does one attempt |

## Test ownership

- Data-definition tests own Action, Flow, component, Ref, Condition,
  Executable, Instruction, structural validation, and executable validation.
- Codec tests own the stored grammar, Registry trust, JSON byte round trips,
  portability, deterministic encoding, and resource limits.
- Compiler tests own native components, ports, connections, source maps,
  instance identity, and compilation digests.
- Exec tests own complete calls, step-wise transitions, validation during a
  call, process ownership, timeout, cleanup, routing, errors, and telemetry.
- A higher-level test can prove one connection between boundaries. It must not
  repeat a complete lower-level matrix.
- Public policy tests use public results and process effects. Focused internal
  owner tests can inspect private state when no public effect can prove the
  local rule.
- Synchronization uses messages, monitors, and barriers. Time sleeps are not
  ordering proof.

## Implemented stages

1. Direct tests fixed the R1, R2, and R3 behavior defects.
2. Exact native Runic graph, ports, connections, and Runnable tests fixed the
   supported Runic contract.
3. One six-form execution matrix now proves timeout, no-dispatch, routing,
   caller cleanup, limiter cleanup, and no fallback.
4. Source maps and compile options now have one strict public grammar.
5. Unused hidden exports and generated Flow wrappers are removed.
6. Codec decode has valid UTF-8 checks and one total work budget.
7. Tests use explicit messages, monitors, and barriers for ordering proof.
8. Public module docs, type contracts, and the target-form telemetry matrix
   now match the approved API levels.
9. Release-facing guide text is corrected. The full known guide rewrite is a
   later documentation task.

## Staged verification

Use three levels for each item:

1. **Focused proof:** Run the new or changed direct contract test.
2. **Subsystem proof:** Run all tests for the boundary owner and its immediate
   consumer.
3. **Release proof:** Run all commands below and inspect the package result.

Release proof:

```text
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix test.integration
mix test --cover --warnings-as-errors
mix quality
mix docs --warnings-as-errors
mix xref graph --format stats
mix hex.build --unpack --output /tmp/jido_action-package-audit
```

Also inspect these facts after a boundary change:

- The public ExDoc module set matches the approved API levels.
- Internal modules do not appear as supported developer API.
- The package has no unintended file or direct dependency.
- Codec version 1 fixtures still round-trip through a trusted Registry and JSON
  bytes.
- Direct, Builder, Spark, and JSON authoring still produce equal canonical
  values.
- Action and Flow error ownership stays exact.
- Native Runic support Runnables stay visible.
- A requested Jido instance never falls back to the global supervisor.
- Exec performs no automatic retry.

## Final verification record

All results below come from the same working tree after the implementation:

| Check | Result |
| --- | --- |
| Focused contract tests | 75 passed |
| `mix test` | 315 passed and 2 excluded |
| `mix test.integration` | 2 passed |
| `mix test --cover --warnings-as-errors` | 315 passed, 2 excluded, 93.13 percent total coverage |
| `mix quality` | Format, compile, Doctor, ExDoc, Credo, and Dialyzer passed |
| Doctor | 100 percent docs, 100 percent module docs, and 92 percent specs for parsed modules |
| `mix docs --warnings-as-errors` | Passed |
| `mix xref graph --format stats` | 54 nodes, 3 compile edges, 69 export edges, 152 runtime edges, and 2 reviewed cycles |
| Runic | Requirement and lock are exactly `0.1.0-alpha.9` |
| Package | Hex build passed; 84 files and 728 KiB unpacked |

The package contains 54 production source files, 24 guides, and the expected
root package files. Tests and both design-plan files are not in the package.
The direct production dependency list stays `telemetry`, `zoi`, `runic`,
`splode`, and `spark`.

## Changes that need direct contract evidence before simplification

Do not replace the Flow concurrency implementation with
`Task.async_stream/3` unless the replacement proves all of these rules:

- ordered results;
- shared execution-wide concurrency permits;
- safe nested concurrency;
- hard process-kill containment;
- Action process isolation; and
- correct Task Supervisor routing for Jido instances.

Do not adopt `Runic.Runner` in this package. It adds managed process,
persistence, store, and scheduling responsibilities. This package needs native
Runic Workflow execution with caller-owned state.

Do not delete `FanIn.map`. It is an active field in installed Runic
`0.1.0-alpha.9`, and Compiler uses it for native Map and Reduce lowering. The
old stale deletion item referred to a duplicate Jido field that does not exist
now.

Do not add aliases, legacy shape inference, duplicate stored models, a Jido
runtime graph, a second scheduler, or a descriptor field in canonical Flow
data.

## Completion conditions

The simplification pass can have a completion claim only when all these
conditions are true:

- All P1 required items have direct passing proof.
- A4 has a recorded supported-Runic-version policy.
- Each P2 item is complete or has a recorded reason and owner for deferral.
- Each A-series item has a recorded decision before related code changes.
- The fixed Spark DSL, canonical Flow, Codec version 1, and native Runic
  contracts are unchanged.
- The developer task map matches the public ExDoc and package API.
- Release-facing guide text changed by this pass contains no stale public
  names or false behavior statements. The known full guide rewrite stays a
  separate documentation task.
- Focused, subsystem, and release verification pass on the same working tree.
- The final audit records exact command results and does not infer missing
  proof from a broad passing check.
