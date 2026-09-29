# Public Contract Register

This register connects critical public promises in `jido_action` to test
oracles and case classes. It is not a complete list of every public function.
The [Actions](actions.md), [Instructions](instructions.md), [Flows](flows.md),
[storage](flow-storage.md), [expressions](flow-expressions.md), and
[execution](execution.md) guides define supported behavior. This guide ships
in the Hex package and ExDoc. Test source stays in the versioned Git checkout.

## Stable IDs And Evidence

One contract ID identifies one caller-visible promise. Keep its ID when wording
becomes more precise. Do not reuse a retired ID. A public behavior change must
update the promise, its required cases, and its tests in the same change.

Tests declare `@tag contracts: ["EXEC-001", ...]`. A property can support several
promises. Tags identify evidence, not complete coverage. Existing default,
authoring, and system tests remain evidence; they do not move into this suite.
Paths below are relative to the package root. Run results are separate from
this register.

An ID is an evidence index, not a coverage unit. One passing property can support
part of a promise while another owner fails. Read per-test results and required
cases before treating a contract as checked.

Properties also declare stable `contract_cases` strings such as
`"EXEC-001/step-claim"`. A passed test reports those cases only when its body
forces them through fixed loops or a fixed sequence. This is a rule for test
authors; the report does not observe case execution. Random command frequencies
are not forced transition coverage. The current random revision model therefore
has contract tags but no forced-case tags. Its fixed sequence has both.

## Actions, Targets, And Instructions

Primary property evidence is in `test/property/action/` and
`test/property/instruction/`. Fixed boundary evidence is in
`test/jido_action/`, `test/jido_instruction/`, and
`test/jido_exec/action_execution_test.exs`.

| ID | Public promise | Forced property cases and oracle |
| --- | --- | --- |
| ACT-001 | Invalid input fails before the Action callback runs. | Missing, string, list, and nil schema input through Action and Flow calls; zero callbacks. Undeclared Action root fields survive validation. |
| ACT-002 | Callback exceptions, throws, exits, invalid returns, and returned errors become structured public errors. | Each failure form through direct, serial Flow, and concurrent Flow calls; original reason or exception and original callback stack frame where applicable. |
| ACT-003 | Normal output validation runs after the callback. | Invalid output through Action and Flow calls; one callback and a structured error without effects. |
| ACT-004 | Intentional non-map success uses an Output envelope; effect requests are proper lists. | Raw, batch, opaque, and lazy stream envelopes; unwrapped scalar rejection; malformed lists rejected; empty effects normalized; duplicate requests retained. |
| ACT-005 | An inline Step becomes an ordinary Action and retains its owner's lexical helpers. | Generated values through the Flow, extracted Action, and direct constructor; equal results; unknown Step name rejected. |
| TARGET-001 | Resolution preserves the exact supported target and kind and rejects invalid descriptors. | Action, Flow module, and Flow value; wrong descriptor owner; unsupported scalar, map, function, and module targets. |
| INS-001 | An Instruction carries call data and uses shallow params/context overrides without turning metadata into policy. | Map and keyword construction; Action and Flow-value execution; nested replacements; false-value preservation; metadata unchanged; nil maps; invalid maps and removed fields rejected. |
| ERROR-001 | Error maps preserve documented type, details, and retry policy while omitting top-level stacktraces. | All Action constructor types; map/keyword details; error tuple wrappers; retry allowed only for execution/timeout errors; unsupported maps cannot select a type or retry. |

## Flow Definition And Storage

Expression properties are in `test/property/expression/`. Fixed grammar and
host integration tests remain in `test/jido_expr/` and `test/jido_expr_test.exs`.

| ID | Public promise | Forced property cases and oracle |
| --- | --- | --- |
| EXPR-001 | Fixed expression operations follow documented native Elixir result and short-circuit rules. | Arithmetic, comparisons, strict membership, concatenation, parsing, Boolean short-circuit, right-value preservation, and invalid operand errors. |
| EXPR-002 | Expression constructors and public limits reject unsupported or oversized input. | Every operator's empty arity; unknown operator; arbitrary source call; depth, nodes, binary bytes, and integer bits above the selected limit. |

Primary property evidence is in `test/property/flow/` and
`test/property/storage/`. Fixed authoring, source rejection, and Codec evidence
remains in `test/authoring/` and `test/jido_flow/`.

| ID | Public promise | Forced property cases and oracle |
| --- | --- | --- |
| FLOW-001 | Equivalent DSL, data definitions, direct constructors, and Codec data produce the same canonical Flow. | DSL, maps, component constructors, and Codec for Step graphs; canonical equality plus an independent arithmetic result; extracted inline Action parity. |
| FLOW-002 | References and needs create dependencies; source order does not. | Chain, diamond, disconnected, fan-in, and fan-out shapes; references-only, needs-only, and combined edges; reversed declarations; prerequisite callbacks precede dependent callbacks. |
| FLOW-003 | Invalid graph definitions return structured validation errors. | Duplicate names, unknown needs, cycles, and nil output through data forms; invalid execution starts no work. |
| FLOW-004 | Validation and inspection do not run Action work. | Valid/invalid structure, executable validation, invalid target contracts, dependencies, explanation, identity, compilation, Codec decode and diagnosis. |
| FLOW-005 | Semantic identity distinguishes references from literal data and survives a Codec round trip. | Reference versus literal reference-map data; identity algorithm/digest shape; compiled semantic digest agrees with public identity. |
| FLOW-006 | Host extensions lower to ordinary canonical declarations. | Extension versus direct and data definitions equality; generated inputs produce the same public result. |
| STORE-001 | Supported JSON versions preserve canonical Flow meaning and deterministic stored-map encoding. | All seven component kinds; versions 1 and 2; nested generated data; atom, integer, and string map keys; decode/diagnose/re-encode. An independent Step document checks exact stored data in both directions. |
| STORE-002 | Stored identifiers resolve through a trusted Registry without creating atoms from unknown identifiers. | Unknown identifiers before/after decode; wrong entry kind; forbidden executable fields; read aliases; canonical write identifiers. |
| STORE-003 | Malformed or oversized stored documents return structured errors. | Root type, unsupported version, invalid UTF-8, nesting above the limit, and collection width above the limit; decode and diagnose. |

Generated DSL graphs use one fixed module name. The suite runs those properties
serially and removes each generated module after the example. It does not create
an unbounded set of module atoms. Component Codec coverage includes Dispatch;
DSL shape generation currently covers Steps. Fixed authoring tests cover the
other DSL component forms and source diagnostics.

## Execution, Effects, And Telemetry

Primary property evidence is in `test/property/execution/` and
`test/property/flow/component_contract_test.exs`. Fixed execution and OTP
regressions remain in `test/jido_exec/` and `test/system/`.

| ID | Public promise | Forced property cases and oracle |
| --- | --- | --- |
| EXEC-001 | An old or concurrently claimed revision cannot start work. | Old step/wave/continue; fixed old-revision sequence; blocked step/wave/continue with competing mutation APIs; error reason, unchanged ready set, and no extra callback. |
| EXEC-002 | Invalid and foreign tokens do not consume current work. | Invalid, foreign, and previous-revision tokens; current ready set unchanged; refreshed tokens complete each callback once. The command model includes old tokens and current continuation calls. |
| EXEC-003 | Full and step-wise modes have the same supported component semantics. | Map, non-associative Reduce, first-match Choice, Iterate, and Subflow against independent result models; empty/duplicate collections; failure and exhaustion; mixed Choice/Map/Reduce with optional Subflow. |
| EXEC-004 | Failure stops new admission while admitted work can finish. | Every serial chain failure position; held concurrent callbacks with pending work; Map and Reduce fail-fast; Map collected errors continue. |
| EXEC-005 | One concurrency cap applies across nested and collection work; Reduce and Iterate stay serial. | Limits 1, 2, and 3 for Steps, Map, nested Maps, Reduce, and Iterate; hold a full batch and measure active callbacks with a private probe. |
| EXEC-006 | Async handles have one owner-bound terminal consumer and handled cancellation stops active work. | Foreign await/cancel/message handling; owner cancellation; owner death; await timeout; message consumption, reuse rejection, and mailbox cleanup. |
| EXEC-007 | Timeout is one complete-call budget, including continuation chains. | Shared decreasing finite budget; blocked final continuation worker; Action and Dispatch roots; zero timeout starts no work. |
| EXEC-008 | Continuations are terminal transitions from authorized positions and share one continuation limit. | Action/Dispatch chains; shared bound; Dispatch rejects step-wise/Subflow use before work; ordinary Step continuation rejects before the next target. |
| EFFECT-001 | Effects preserve canonical dependency, name, nested, and collection order and request multiplicity. | Serial/concurrent graph parity; each successful node once; nested position; Map input order, Reduce order, Iterate order, duplicate and opaque requests. |
| EFFECT-002 | Failure, timeout, and cancellation return no executable effect batch. | Each failure position after prior work; invalid output/effects; Choice failure, collected failed items, exhaustion, await and complete-call timeouts, cancellation. |
| OBS-001 | Started telemetry lifecycles close once at a handled terminal result with the documented execution ID and measurements. | Nested success/failure, serial/concurrent execution, and explicit cancellation; start/terminal counts, stable metadata, one execution ID, non-negative integer durations. |

The generated command model remains sequential and uses independent Steps.
The fuzz variant includes failed terminal states, foreign tokens, and competing
claims with explicit callback barriers. It does not model dependent support work
or arbitrary parallel histories. Repeated child
telemetry spans can share public metadata; tests compare start and terminal
multiplicity rather than inventing a public span identifier.

## Run And Measure

Run from a source checkout:

```sh
mix test.property --warnings-as-errors
mix test.fuzz --warnings-as-errors --seed 123
mix test test/property/flow --only property --seed 123
mix test test/property/execution --only property
mix test.authoring
mix test
```

Default `mix test` excludes the property and fuzz suites, including the fixed
command sequence. It does not start PropCheck or open its counterexample store.
A selected property or fuzz run writes `_build/test/property-report.json` (or the selected
Mix build path). The report records the revision, dirty-checkout flag, package
version, Elixir/OTP versions, ExUnit seed, per-test results, contract evidence,
and declared forced case IDs. Missing contract evidence and unknown IDs remain visible.

A forced case contributes to `declared_forced_cases_in_passed_tests` only when
its owning test passes. Tags remain declarations, not execution measurements.
This is conservative case evidence, not a count of individual generated inputs, random model
transitions, branch coverage, or a correctness probability. Keep the report
with CI artifacts for the revision tested. The report marks incomplete and failed
runs and records selection filters. Git metadata can be null outside a checkout.
CI must remove old reports before Mix starts and also check the Mix exit status;
early build failures can occur before the report starts. Do not copy changing
counts into this guide. See `test/property/README.md` for report use, replay,
framework tradeoffs, and cleanup.

The `:fuzz` tag selects separate cases with larger bounded inputs and more samples.
The `:property` tag selects short checks. Budgets are ExUnit tags, and default runs
exclude both suites. All fifteen fuzz cases record actual attempts and passing
observations separately from static tags. Fourteen cases save reduced JSON inputs;
the revision case saves native PropCheck command terms. Both formats replay before
new generation. Generated
release priorities exercise async success, failure, and cancellation after prior
effects. This is controlled callback ordering, not deterministic BEAM scheduling
or coverage-guided generation.

The report's `contract_evidence_by_suite` separates property and fuzz evidence.
A passing short property cannot fill a missing fuzz contract. Measured records
include the owning test's contract IDs, declared forced cases, and timeout.
Saved JSON failures include contract IDs. Native command failures are linked from
a measured record with contract IDs, so both can be traced to a public promise.

## Fuzz Contract Plan

All 15 cases in this plan are implemented. They map to all 30 registered
promises. A passing case provides evidence for its tested clauses, not proof
of the complete contract. One case can check several related contracts. Each
case has an expected result and a generator that can reduce a failure.

| Case and status | Contract IDs | Generated variation | Expected result or check |
| --- | --- | --- | --- |
| `graph_semantics` — implemented | FLOW-001, FLOW-002, STORE-001, EFFECT-001 | DAG edges, values, declaration order, direct/data definitions/Codec forms, and execution limits | Independent arithmetic and dependency-depth/name models check values and ordered effects; encoding stays stable. This case does not generate DSL source. |
| `mixed_components` — implemented | EXEC-003, EFFECT-001 | Choice, Map, non-associative Reduce, optional Subflow, collection sizes, and execution modes | An independent list calculation checks full, step, wave, and continue results and effects. |
| `async_schedules` — implemented | EXEC-004, EXEC-006, EFFECT-001, EFFECT-002 | Worker release ranks, concurrency limits, stop positions, success, failure, and cancellation | Ready/release messages check effects, stopped admission, handle reuse, and owned process cleanup. |
| `codec_mutations` — implemented | FLOW-003, FLOW-004, STORE-002, STORE-003 | Change one known field or boundary in a valid stored document: kind, reference, Registry ID, version, UTF-8, depth, width, or node count | Known-invalid changes return structured errors and start no work. Unknown identifier strings do not become atoms. Use selected mutations with known outcomes, not arbitrary byte changes with guessed outcomes. |
| `iterate_state` — implemented | EXEC-003, EXEC-004, EXEC-005, EFFECT-001, EFFECT-002 | Initial State, replacement State, schema failures, stop conditions, body failures, and iteration bounds | An independent recurrence checks result, call count, serial order, and exhaustion without an extra call. Failed execution returns no effect batch. |
| `nested_execution_failures` — implemented | EXEC-003, EXEC-004, EXEC-005, EFFECT-002 | Bounded Choice/Subflow/Map/Reduce combinations, failure positions, Map error modes, and shared concurrency limits | A small reference model checks the selected error policy. Callback barriers check the active-work bound, serial Reduce, stopped admission where required, and cleanup. |
| `codec_portability` — implemented | STORE-001, STORE-002, FLOW-005 | All component kinds, supported versions, nested portable values, Registry aliases, and literal/reference distinctions | Independently written stored examples check encoding and decoding. Round trips check meaning and identity; aliases resolve only to trusted entries. |
| `expression_trees` — implemented | EXPR-001, EXPR-002 | Bounded valid trees, operand types, short-circuit branches, and deliberate arity/depth/node/size violations | A small native Elixir evaluator checks supported operations. Known-invalid trees return errors; unselected branches do not run. |
| `action_boundaries` — implemented | ACT-001, ACT-002, ACT-003, ACT-004, ERROR-001, EFFECT-001, EFFECT-002 | Schema inputs, output envelopes, proper/improper effect lists, callback failure forms, and error details | Callback records check validation order. Public results check normalization, retained error data, retry rules, effect order, duplicate effects, and effect removal on failure. |
| `instruction_targets` — implemented | INS-001, TARGET-001 | Action/Flow targets, descriptors, params, context, metadata, and shallow overrides | An independent shallow-merge model checks call data. Resolution preserves the exact target and kind; metadata stays inert; invalid descriptors fail. |
| `graph_rejections` — implemented | FLOW-003, FLOW-004 | Duplicate names, missing dependencies, cycles, invalid output, and invalid executable targets through public data forms | Known-invalid graphs return structured errors. Validation and inspection start no Action work. |
| `authoring_equivalence` — implemented | FLOW-001, FLOW-006, ACT-005 | Generated DSL graphs, plus values through fixed inline-Step and host-extension templates against direct and data definitions forms | Canonical equality and independent result calculations check lowering and extracted Actions. Reuse fixed module names, run serially, and remove generated modules. |
| `revision_histories` — implemented | EXEC-001, EXEC-002 | Longer valid command sequences with stale revisions, foreign tokens, competing claims, and terminal failed states | An independent PropCheck state model checks successful and failed states. Each revision starts work at most once; invalid tokens consume nothing. Native sequence shrinking and saved command replay preserve valid histories. |
| `continuation_chains` — implemented | EXEC-007, EXEC-008, EFFECT-002 | Action and terminal Dispatch chains, target kinds, chain bounds, invalid positions, and blocked final work | Check authorized terminal transitions, one shared chain bound, and no effects on timeout or failure. Callbacks must retain an earlier, supplied absolute deadline; a separate finite call timeout stops blocked final work. |
| `telemetry_lifecycle` — implemented | OBS-001 | Nested success, failure, cancellation, collection event selection, and component counts | Match each start with one terminal event by public metadata and multiplicity. Check one execution ID, required fields, and non-negative measurements; detach each handler. |

Fixed examples force required boundary classes. Random observations are counted
separately. Tests declare `:fuzz`, `contracts`, and only the `contract_cases`
that their bodies force. Short and fuzz cases share assertions where they check
the same promise. The source checkout's `test/property/README.md` lists their
sample and input-size limits.

Every fuzz case has an **ExUnit timeout of 15 minutes**. The fourteen StreamData
cases allow **5 minutes of discovery**, or their sample count, whichever comes
first. The native PropCheck revision case uses 500 histories, a maximum size
of 100, and 200 shrink steps; its overall ExUnit timeout bounds the run. It does
not use StreamData's discovery-time option. Fixed examples, replay, shrinking,
and cleanup also need time within the overall test timeout. The three paired
short cases retain 10 seconds of discovery and a 90-second timeout.

Budgets are ordinary ExUnit tags. Callback readiness and cleanup retain finite
limits so stalled work fails promptly. Schedules use messages and monitors.
The deadline case checks the documented absolute deadline, not only decreasing
remaining-time values. It uses `timeout:` to test controller enforcement;
budget metadata by itself does not add a controller timer.

## Limits And Further Evidence

Fixed tests still own exact source diagnostics, every schema option, all DSL
component forms, abrupt mutation interruption, blocked host startup/telemetry,
and exhaustive malformed Codec diagnostics. Generated tests do not cover those
complete matrices, arbitrary component mixtures, or every public option
combination. Fuzz tests now include document node limits, State schema failures,
Instruction Flow-module calls, and selected collection telemetry fields.
Validator failure forms, trapped-exit cleanup, and completion/cancellation races
retain fixed evidence. Absolute-deadline equality checks propagation; it does
not prove every timer race or host startup path.

Fault detection and shrinking were checked with temporary faulty graph and
revision adapters during the initial spike. There is no maintained production
mutation set or mutation score. Preserve real reduced failures as fixed
regressions and add deliberate faults to a separate measured check when needed.

This package owns in-memory execution. Durable recovery, persistence, queues,
distributed coordination, and retry policy are outside its scope. Worker
termination after arbitrary caller, controller, or scheduler death is not
guaranteed. These are scope limits, not missing coverage.
