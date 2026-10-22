# Public API Contract Review

## Review status and scope

This is the source review of `jido_action` on 2026-10-14, on `release/v3`,
with base commit `0374d195`. The worktree includes earlier Covenant changes.
The initial review used local Runic at `../runic`, commit `de170d8`.
The implementation check record below identifies the later dependency build.
Results apply to these source combinations, not to every published release.

Read the [detailed public API reference](public-api-reference.md) for exact
entry points, generated APIs, callbacks, data, defaults, errors, ordering,
effects, identity, storage, telemetry, and source/test evidence. This review
selects behavior obligations. It does not replace that API reference.

The review covered every file under `lib/`, including hidden exported
helpers and native Runic protocol implementations. It compared source with
the README, usage rules, guides, the 36 public register entries, the 42
original detailed obligations, and relevant ordinary/property tests.
Reading a test is evidence of its assertions, not proof that every case in a
broad promise passes. The check record below separates tests run during this
review from tests inspected as evidence.

The initial review changed documentation only. The subsequent implementation
fixes Choice routing, corrects documentation, and consolidates obligations and
test tags. The changes are included in a local checkpoint commit.

## Recommended promise set

Use these **15 public promise groups**, instead of 78 parallel
obligations (36 register entries plus 42 detailed entries). `P01` through
`P15` are review labels, not new Covenant IDs or active tags. They refine the
initial 15 groups. Keep source/API compatibility for all supported functions,
including those that do not need a separate Covenant obligation.

Each group below has an acceptance matrix. The active obligations split those
groups into focused facets. Tests contribute evidence for the stated facet;
a passing tag alone does not establish the entire group or matrix.

| Candidate | Proposed behavior obligation | Required acceptance matrix and limits |
| --- | --- | --- |
| P01. Definitions and descriptions | Valid static Action and Flow configuration produces the documented metadata, schemas, callbacks, and kind. Action requires `run/2`. Tool descriptions preserve the declared meaning or report a projection error. | Action and Flow; missing callback; all config fields; invalid/static schemas; one-time evaluation; absent schemas; JSON projection success and delayed failure. Successful compilation does not imply `authoring_contract/0` can succeed. |
| P02. Shared validation | Input validation precedes work; output validation follows successful work. Defaults, coercion, transforms, preparation, and root unknown-key policy retain their declared meaning at Action and Flow boundaries. | Root Action, root Flow, nested Flow, and Dispatch-selected Flow; direct object/struct versus nested/wrapped schema; strict/typed keys; custom validator failures and invalid returns; transformed shape and exactly one application per boundary. Direct validator calls do not provide all Exec containment. |
| P03. Calls and targets | Instructions retain call data and resolve the current target contract. Overrides are shallow; metadata cannot choose execution policy. Inert templates and binding keep their separate input rules. | Module and Flow values; nested Instructions; each merge layer; constructor, template, binding, callback checks, reload and stale kind, removed fields, failure variants. Resolution can load trusted modules but does not run Action work. |
| P04. Results and errors | Exec preserves supported success/envelope forms, contains callback failures, and retains useful public error type, reason, location, and retry classification. | All four Output kinds and stream laziness; invalid raw output; raise/throw/exit/kill; invalid validators/returns; Action and Flow maps; grouped errors; retry hints; top-level versus detail stacktraces. Native managed lookup/control errors can be atoms. Error maps are not JSON transport data. |
| P05. Deferred effects | Successful execution returns ordered effect requests without dispatch. It preserves duplicates; rejected/failed output exposes no executable batch. Logical effect identity excludes attempt identity. | Action, independent/dependent components, unselected output branches, nested Flow, Map successes/collected failures, Reduce, Iterate, Dispatch; proper/improper lists; rejected output; timeout/cancel/uncertainty; effect identity with fixed execution/activation/output/index. A changed output ID can change the effect ID. |
| P06. Graph rules | References and `needs` define dependencies; source order does not. Every Flow has an explicit output. Invalid graph structure and reference scope fail with useful diagnostics. | Required final DSL output and non-nil data output; missing names; duplicates; cycles; reference scopes; Dispatch terminal/output rule; stable diagnostic order for the documented phases. Dispatch is the sole graph terminal, not necessarily the final source component. |
| P07. Component meaning | Choice, Map, Reduce, Iterate, nested Flow, and Dispatch keep their declared value, selection, state, and failure rules. | A separate case family for each component, including empty collections, duplicate items, fail-fast/collect-errors, serial folds/iterations, state validation/exhaustion, nested boundaries, direct/continued Dispatch. The Choice `"fallback"` collision is repaired with distinct internal routes and a regression test for matching and nonmatching conditions in serial and concurrent execution. |
| P08. Authoring equivalence | DSL, data definitions, and stored documents express the same supported Flow meaning. Inline Steps act as ordinary Actions with owner scope. Extensions lower to supported declarations. | Equivalent graphs with refs/expressions/schema transforms/all components; Inline lexical scope, lookup, reuse and build deployment; extension versus direct declarations; rejected declarations. Equal meaning does not require identical generated module names or AST. |
| P09. Expressions | Fixed operations keep their documented Elixir results and short-circuit rules. Parsing, host callbacks, validation, and evaluation keep a closed grammar and apply their stated resource limits. | Every operator/arity, term ordering, strict membership, right-value Boolean returns, skipped operands, parser rejection, pins/host values, callback failures/paths, cumulative depth/node/binary/integer bounds. `new/2` checks operator and arity only. A constructor example cannot establish bounded evaluation. |
| P10. Stored documents | Portable authoring primitives provide owner-neutral resource limits, a closed value grammar, and typed host identifiers. Document `vsn` 1 preserves Flow meaning and deterministic stored-map representation. Registry lookup creates no atoms. Invalid or oversized documents return useful errors. | Shared Registry, Value, Document, and second-owner composition; every Flow field/component/value tag; explicit `vsn` values and kind mismatch; unknown ID atom safety; map-key ordering/duplicates; round trips; safety limits; independent diagnostics and phase order. JSON byte order, generated-ID stability across changed registries, and deployed code snapshots are excluded. |
| P11. Inert inspection and identity | Flow validation, inspection, and Exec compilation do not run Action work. Diagnostics retain useful locations. Semantic identity reflects canonical graph data and distinguishes refs/expressions from literals. | validate/dependencies/explain/identity/compile; target-contract check versus inert structural check; identity sensitivity and exclusions; Codec round trip; DSL source paths. Trusted metadata/schema/Flow builders may run during compilation. Identity does not identify deployed Action code. |
| P12. Execution policy | Timeout is per attempt. Only eligible errors retry. Failure stops new admission while admitted work can finish. Concurrency preserves defined result, effect, and failure order. | Serial and concurrent runs; nested and collection work; each retry policy; non-retryable failures; timeout zero/finite/infinite; failure ordering after active work drains; malformed options. Runtime scheduling and admission are Runic-owned. |
| P13. Process ownership | Immediate work cannot crash its live caller and is stopped when that caller dies. Owned tasks are released on completion and termination. Managed work follows Runner ownership. | Caller normal/abnormal exit; timed and untimed work; group leaders; injected and partitioned supervisors; task crash; managed stop/cancel/worker death; failed persistent stop. Custom executors and unlinked user processes need their own contracts. |
| P14. Managed result and recovery | Managed and manual execution preserve the same Flow meaning. Results respect the admitted input scope and distinguish active, failed, stopped, and uncertain work. Recovery preserves acknowledged stored progress; context and policy must be supplied again. | Manual units, busy/complete states, live observations, later input occurrences, foreign results, resume snapshot fallback, checkpoint and Store failure, each recoverable component, portable params/metadata/context/results/effects, duplicate and rejected starts. Computed success is separate from Store acknowledgement. Work after the last acknowledged checkpoint can repeat. |
| P15. Telemetry | Jido emits the documented Action-attempt and immediate-Flow event shapes with stable correlation fields and bounded start/stop metadata. Runic owns managed runtime events. | Event list/measurements; success/error/retry; nested and Dispatch metadata; immediate versus managed events; privacy keys; timeout/kill paths. Action start does not guarantee Action stop on timeout or process death. |

These candidates can use many ordinary tests. They are small in number, not
small in evidence needs. P07 and P14 in particular require a visible matrix;
a single example of Choice or a ten-step checkpoint is insufficient.

## Active Covenant mapping

The implementation now uses **48 focused obligations in 15 promise groups**.
It merges overlapping detailed requirements, removes the 36 duplicate public
register requirements, and adds focused graph, storage, policy, ownership,
recovery, effect, and telemetry evidence. Existing normal tests remain.
Old IDs that were merged are no longer active and must not be reused.

Covenant reports whether an active obligation has passing tagged evidence and
whether any tagged tests fail. It does not require every acceptance-matrix
case to run. Read the matrix and test assertions before claiming full coverage.
There is no custom coverage framework or environment switch.

All IDs below have the `jido_action.` prefix.

| Group | Public promise | Active obligation facets |
| --- | --- | --- |
| P01 | Definitions and descriptions | `action.I1, action.I2` |
| P02 | Shared validation | `validation.I1–I3, boundary.I1, boundary.I3` |
| P03 | Calls and targets | `instruction.I2–I6` |
| P04 | Results and errors | `errors.I1, errors.I3–I4, output.I1–I2, boundary.I2, boundary.I4` |
| P05 | Deferred effects | `execution.I19, execution.I24` |
| P06 | Graph rules | `flow.I8` |
| P07 | Component meaning | `execution.I17, boundary.I7–I9` |
| P08 | Authoring equivalence | `flow.I7, flow.I11, inline.I1–I3` |
| P09 | Expressions | `expression.I1–I4` |
| P10 | Stored documents | `authoring.I1–I3, codec.I5–I7` |
| P11 | Inspection and identity | `flow.I9–I10, boundary.I5` |
| P12 | Execution policy | `execution.I18, boundary.I6` |
| P13 | Process ownership | `execution.I20` |
| P14 | Managed results and recovery | `execution.I21–I22, boundary.I10` |
| P15 | Telemetry | `execution.I23` |

Merged IDs: action I3→I1 and I4→I2; instruction I1→I2 and I7→I3;
errors I2→I1 and I5→I3; output I3→I1; validation I4→I1; inline I4/I5→I2.
Implementation assertions in these test families remain normal checks, not
separate compatibility promises for private helper functions or node layouts.

The mappings below retain the original review as migration history. The IDs
in those historical tables are not the current active contract inventory.

## Mapping the 36 public register entries

The Covenant IDs below identify the original added entries. This table records
the initial migration proposal. Use the active mapping above for current IDs.
`Normal` means keep the implementation assertion in ordinary tests; preserve
the supported observable behavior under the named candidate.

| Register ID | Original Covenant ID | Candidate and treatment |
| --- | --- | --- |
| ACT-001 | `jido_action.boundary.I11` | P02; duplicate of detailed boundary I1 and parts of action I3/validation I1-I3. |
| ACT-002 | `jido_action.boundary.I12` | P04; duplicate of detailed boundary I2. |
| ACT-003 | `jido_action.boundary.I13` | P02/P04; duplicate of detailed boundary I3. |
| ACT-004 | `jido_action.boundary.I14` | P04 envelopes; P05 effect-list rule. Reuse detailed Output/boundary evidence. |
| ACT-005 | `jido_action.inline.I6` | P08; duplicate of detailed inline I2/I5. |
| TARGET-001 | `jido_action.instruction.I8` | P03; detailed instruction I3/I5/I6 already separate target cases. |
| INS-001 | `jido_action.instruction.I9` | P03; duplicate of detailed instruction I3/I4 and template/binding context. |
| ERROR-001 | `jido_action.errors.I6` | P04/P12; detailed errors I1-I4 establish distinct map/retry facets. |
| EXPR-001 | `jido_action.expression.I5` | P09; duplicate of detailed expression I1. |
| EXPR-002 | `jido_action.expression.I6` | P09; overlaps detailed expression I2-I4. Narrow the construction wording for `new/2`. |
| FLOW-001 | `jido_action.flow.I1` | P08; all three authoring forms, not one round-trip example. |
| FLOW-002 | `jido_action.flow.I2` | P06; reference and explicit-order cases. |
| FLOW-003 | `jido_action.flow.I3` | P06/P10; separate graph and stored field diagnostics. |
| FLOW-004 | `jido_action.flow.I4` | P11; inert Action work, with trusted host-code limits. |
| FLOW-005 | `jido_action.flow.I5` | P11; identity distinctions and Codec equivalence. |
| FLOW-006 | `jido_action.flow.I6` | P08; extension lowering and rejection. |
| STORE-001 | `jido_action.codec.I1` | P10/P08; deterministic maps and preserved meaning. |
| STORE-002 | `jido_action.codec.I2` | P10; merge its trusted lookup evidence with SECURITY-001. |
| STORE-003 | `jido_action.codec.I3` | P10; fields, limits, and diagnostic phases. |
| EXEC-001 | `jido_action.execution.I1` | P03/P11 for executable target integration. Normal for the exact one-node representation. |
| EXEC-002 | `jido_action.execution.I2` | P06/P07/P11 for executable meaning. Normal for private node and edge layout. |
| EXEC-003 | `jido_action.execution.I3` | P07; requires a per-component matrix. Choice collision blocks the full claim. |
| EXEC-004 | `jido_action.execution.I4` | P12; stopped admission and admitted work. |
| EXEC-005 | `jido_action.execution.I5` | P12/P07; shared concurrency and serial folds/iterations. |
| EXEC-006 | `jido_action.execution.I6` | P14; one scheduler unit, not necessarily one authored Step. |
| EXEC-007 | `jido_action.execution.I7` | P15; include the missing-stop limitation. |
| EFFECT-001 | `jido_action.execution.I8` | P05; one ordering family across components and concurrency. |
| EFFECT-002 | `jido_action.execution.I9` | P05/P04; overlaps detailed boundary I2-I4. |
| DURABLE-001 | `jido_action.execution.I10` | P14 example; stop after 5/resume at 6 is not a separate general promise. |
| DURABLE-002 | `jido_action.execution.I11` | P14; change the proposed wording to acknowledged stored completed work. |
| DURABLE-003 | `jido_action.execution.I12` | P14/P07; each dynamic component needs recovery evidence. |
| DURABLE-004 | `jido_action.execution.I13` | P14 for persistence behavior. Normal for absence of a second private checkpoint format. |
| DURABLE-005 | `jido_action.execution.I14` | P05; effect identity needs the same output ID as well as activation ID. |
| SECURITY-001 | `jido_action.codec.I4` | P10; duplicate of STORE-002, not a second coverage requirement. |
| SECURITY-002 | `jido_action.execution.I15` | P14; extend evidence to metadata, output and effects, not params/context alone. |
| SECURITY-003 | `jido_action.execution.I16` | P01/P03/P12/P14; each boundary has its own option/error rules. Do not claim all malformed Elixir terms are contained. |

## Mapping the 42 original detailed obligations

Each row below is one original obligation. The public register additions
listed above are excluded from this count. `Normal` does not authorize removal
of a regression test or change of public behavior.

| Original obligation | Candidate and disposition |
| --- | --- |
| `jido_action.action.I1` | P01 metadata/descriptions; retain delayed projection failure cases. Kind-marker spelling stays Normal. |
| `jido_action.action.I2` | P01 static configuration, map-compatible schemas, one-time evaluation. Escape/compiler implementation details stay Normal. |
| `jido_action.action.I3` | P02 shared validation; overlaps validation I1-I3 and boundary I1/I3. |
| `jido_action.action.I4` | P01 required callback; no separate obligation for one generated callback. |
| `jido_action.boundary.I1` | P02 input order, transformation, invalid validator and nested boundaries. |
| `jido_action.boundary.I2` | P04 failure conversion; P05 discarded effects; P07 continuation position. |
| `jido_action.boundary.I3` | P02/P04 output boundary; P05 rejection of effects with invalid output. |
| `jido_action.boundary.I4` | P04 envelope/laziness; P05 proper lists, order, duplicates. |
| `jido_action.boundary.I5` | P03/P11 for native protocol behavior and rebuild meaning. Normal for exact struct, one-node layout, private hash and source AST. |
| `jido_action.boundary.I6` | P03/P12/P14 invalid target/policy handling. Native control atoms must remain exceptions to the blanket structured-error wording. |
| `jido_action.boundary.I7` | P07 Map values/errors/item identity; P05 item effects. Normal for parent-Fact layout and linear storage checks. |
| `jido_action.boundary.I8` | P07 Dispatch; P05 effects. Normal for private reconstruction helpers; retain public rebuild integration evidence. |
| `jido_action.boundary.I9` | P07 Reduce/Iterate state and positions; P04 failure details. |
| `jido_action.boundary.I10` | P14 portability, rejected-start cleanup, duplicate worker protection; P13 cleanup lifetime. |
| `jido_action.errors.I1` | P04 constructor data and concrete error types; use a constructor table test. |
| `jido_action.errors.I2` | P04 class/leaf compatibility. General Splode aggregation mechanics stay Normal. |
| `jido_action.errors.I3` | P04 maps and retry fields; do not promise transport conversion or recursive sanitization. |
| `jido_action.errors.I4` | P04 classification/P12 actual retry admission. Share classification evidence; execution needs its own case. |
| `jido_action.errors.I5` | Normal transport-encoding test. Document caller-owned conversion under P04; absence of a JSON protocol needs no separate Covenant obligation. |
| `jido_action.expression.I1` | P09 fixed operators and native value semantics. |
| `jido_action.expression.I2` | P09 grammar and trusted host/pin boundary. |
| `jido_action.expression.I3` | P09 traversal callbacks, exact paths and inert resolved data. Private walk records stay Normal. |
| `jido_action.expression.I4` | P09 bounded processing; keep the separate limits for each public entry point. |
| `jido_action.inline.I1` | P08 accepted host grammar and source-aware rejection. Parsed record shape stays Normal. |
| `jido_action.inline.I2` | P08 owner lexical scope and normal Action behavior; P01 static metadata. Emitted AST shape stays Normal. |
| `jido_action.inline.I3` | P08 typed lookup/inertness. Generated module names and index layout stay Normal. |
| `jido_action.inline.I4` | P08 safe host composition and diagnostic locations. Hook order mechanics and reserved generated function names stay Normal. |
| `jido_action.inline.I5` | P08 Flow host behavior/equivalence, plus P02 validation. Reuse Inline host evidence rather than duplicating ACT-005. |
| `jido_action.instruction.I1` | P03 inert templates. |
| `jido_action.instruction.I2` | P03 binding and raw params; do not confuse bind inputs with normal resolve inputs. |
| `jido_action.instruction.I3` | P03 construction and removed fields. |
| `jido_action.instruction.I4` | P03 shallow flattening/overrides and metadata separation. |
| `jido_action.instruction.I5` | P03 current module kind and reload. |
| `jido_action.instruction.I6` | P03/P11 callback checks without Action work. |
| `jido_action.instruction.I7` | P03 raising forms; `normalize!` classification needs a docs decision. |
| `jido_action.output.I1` | P04 constructor value/metadata rules. |
| `jido_action.output.I2` | P04 envelope failure through supported validators. Hidden helper detail remains Normal. |
| `jido_action.output.I3` | P04 stream laziness; must have its own observable non-enumeration case. |
| `jido_action.validation.I1` | P02 public schema transformations and map shape. Shape-preserving internal helper modes stay Normal. |
| `jido_action.validation.I2` | P02 root versus nested/wrapped policy; share Action/Flow evidence. |
| `jido_action.validation.I3` | P02/P04 parse and callback errors; shared helper rescue cases stay Normal where they have no supported public input. |
| `jido_action.validation.I4` | P01/P02 accepted public schema categories. Internal classifier support for lazy/scalar helper data stays Normal; it cannot imply public Action support. |

## Review findings and corrections

| Original finding | Source and evidence | Correction or limit |
| --- | --- | --- |
| Choice option `"fallback"` can select the wrong branch. | [Choice construction](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_flow/component.ex), [Choice runtime](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec/node/choice.ex), [selector](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec/node/choice/selector.ex). A read-only probe accepted the name, then returned the default target for `true` and the option target for `false`. | Fixed: distinct option/default routing identities and regression coverage for both conditions at concurrency 1 and 4. The initial probe remains historical evidence of the defect. |
| The initial group 1 promised usable JSON-safe descriptions at compilation. | [Authoring compiler](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_authoring/compiler.ex), [Action tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_action/action_test.exs), [API tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/api_test.exs). | `authoring_contract/0` can raise later for invalid UTF-8 Action metadata or unsupported schema projection. Execution can still work. Document projection separately from validation. |
| Broad open-schema rules omit strict, typed, nested and wrapped cases. | [Usage rules](../usage-rules.md), [shared validation](../lib/jido_action/validation.ex), [schema boundary tests](../test/jido_action/parse_contract_test.exs). | Fixed: direct, nested, and wrapped schemas use their declared Zoi policy. Runtime transforms and validators still meet the map/envelope boundary. Parsed root structs become complete plain maps. |
| Boolean wording is too strict in usage rules. | [Expression runtime](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_expr/runtime.ex), [Elixir conformance tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_expr/elixir_conformance_test.exs). | `and`/`or` require a Boolean left operand, then return the evaluated right value unchanged. Flow condition slots separately require a Boolean final value. |
| Expression construction does not always enforce full limits. | [Expression facade](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_expr.ex), [parser](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_expr/parser.ex), [expression tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_expr_test.exs). | `new/2` checks operator/arity only. Trusted parser leaves and macro pins require later validation. P09 must name the entry point. |
| Dispatch “last component” wording implies source order. | [Flows guide](flows.md), [usage rules](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/usage-rules.md), [graph validation](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_flow/graph_validation.ex). | Dispatch must be the sole graph terminal and the complete Flow output. Dependency order is authoritative. |
| Collection and Reduce initial rules are narrower in guides than in source. | [Map collection](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec/node/map/collection.ex), [Loop](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec/node/loop.ex), [error-path tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/error_paths_test.exs). | Runtime accepts Enumerables; only lists give the stated input order independently of an Enumerable implementation. Reduce initial can be an Output envelope. Avoid promising an arbitrary Enumerable's order or resource bound. |
| “Completed Actions do not run again” is unqualified. | [Managed guide](managed-execution.md), [recovery tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/runner/durability_test.exs), [Exec](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec.ex). | Only completed work in acknowledged stored progress is preserved. A crash before checkpoint can repeat work. No exactly-once execution or effect delivery. |
| A computed result can coexist with failed persistence. | [Observation tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/observation_test.exs), [failed persistent stop](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/runner/task_ownership_test.exs). | P14 must require separate Store-status evidence. The synthetic observation test does not prove every failing Store path. Default Store durability is adapter-specific. |
| Live scope and restored scope differ. | [Exec result forms](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec.ex), [Runner observation tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/runner/observation_test.exs). | Live results select the initial input occurrence. Resume loses process-local observations and uses guarded snapshot projection, including historical failure/uncertainty. Do not promise reconstruction of all observations. |
| Every started Jido span is required to stop in contributor rules. | [Contributor rules](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/AGENTS.md), [telemetry source](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_exec/telemetry.ex), [telemetry tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/telemetry_test.exs), [execution guide](execution.md). | Timeout or death can leave an Action start without stop. The test for outer Flow stop on task kill does not establish an Action stop. Caller death also prevents a universal Flow-stop promise. |
| Every Exec failure is described as an exception. | [Errors guide](errors.md), [error-path tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/error_paths_test.exs). | `step/2` and Runner result lookup can return native atom reasons such as `:not_found`. Invalid Runner/process calls are not all contained. |
| Flow error conversion sounds recursive for arbitrary nested detail data. | [Flow errors](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_flow/error.ex), [error tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_flow/error_test.exs). | Group members are mapped recursively; leaf `details` can retain exceptions, stacktraces, and nonportable values. JSON conversion belongs to the caller. |
| Public/internal classification conflicts. | [Contributor rules](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/AGENTS.md), [Codec](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_flow/codec.ex), [Instruction](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_instruction.ex), [usage rules](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/usage-rules.md), [protocol tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/rebuild_test.exs). | Codec facade is public; Codec helpers are internal. `normalize!` is now identified as an internal raising helper. Runic integration is tested, while use rules discourage direct feeding. Advanced protocol integration remains documented without promoting private node constructors. |
| Registry/template construction is not complete target or portability validation. | [Registry](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_flow/registry.ex), [Instruction](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_instruction.ex), [portable tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_exec/portable_test.exs). | Registry accepts typed host entries before executable/schema checks. Template checks map metadata, not portable content. Compile/managed start enforce later boundaries. |
| Storage diagnosis order differs from the guide; malformed DSL errors are not uniform. | [Reader](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/lib/jido_flow/codec/reader.ex), [storage guide](flow-storage.md), [DSL needs tests](https://github.com/agentjido/jido_action/blob/0374d195915c91e4097803c404f02b00d76573cb/test/jido_flow/dsl/needs_test.exs). | Safety precedes envelope checks. DSL invalid data can raise CompileError, Spark.Error.DslError, or FunctionClauseError. Do not promise one universal error family for arbitrary macro AST. |

The source bug and conflicting guide rules above are corrected. The rows
retain the review evidence and the limits that the documentation must state.

The detailed reference records additional limits: no per-Action external
resource cleanup, no JSON byte canonicalization, no deployed-code digest,
no semantic guarantee for forged private structs, and no complete schema
projection from Zoi to tool descriptions. These limits are part of the API
review, not new implementation obligations.

## Evidence plan

Use existing test families for the same observable promise. Do not credit
both an old detailed ID and a new register ID for the same assertion as if
that were new coverage. Keep separate cases where behavior differs:

- P01-P04: Action metadata/configuration, schema pipelines, target reload,
  envelope laziness, validator/callback faults, and both error families.
- P05-P08: independent graph effects, per-component semantics, nested and
  dynamic boundaries, all authoring forms, Inline hosts, and extensions.
- P09-P11: all expression operations and limits, stored tags and limits,
  inert inspection, diagnostic order, and identity exclusions.
- P12-P15: scheduling/admission, task ownership, each recovery mode, live
  result scope, Store status, portable data, and terminal telemetry limits.

Keep generated names, internal node count, parser records, private Flow
frames, index maps, compiler AST, protocol implementation layout, and linear
Fact storage in normal tests. These checks can still prevent serious bugs.
Their existence does not require a public obligation per implementation
function. Native protocol reconstruction remains useful integration evidence
for public behavior, even when its private layout assertions stay Normal.

Use the active facet mapping for Covenant changes. Keep the acceptance
matrix visible and add evidence when a specific case is missing. Do not infer readiness from total passing tag counts, from old saved
coverage files, or from a narrow mutant kill rate.

## Check record

The focused execution command passed **86 tests** on Elixir 1.20.4 / OTP 29,
with seed 0:

```text
ERL_FLAGS='+S 4:4' mix test test/jido_exec/api_test.exs \
  test/jido_exec/observation_test.exs test/jido_exec/telemetry_test.exs \
  test/jido_exec/portable_test.exs test/jido_exec/runner --seed 0
```

The runtime needed a local TCP lock outside the filesystem sandbox. The test
run emitted existing Runic compiler warnings. It was not a
warnings-as-errors check. No dependency was fetched or changed.

A second focused command passed **198 tests** with seed 0. It checked
metadata, shared schemas, Output, target resolution, expression conformance,
Codec, Registry, identity, and execution validation:

```text
ERL_FLAGS='+S 4:4' mix test test/jido_action/action_test.exs \
  test/jido_action/open_validation_contract_test.exs \
  test/jido_action/output_test.exs test/jido_instruction/target_test.exs \
  test/jido_expr/elixir_conformance_test.exs test/jido_flow/codec_test.exs \
  test/jido_flow/generated_registry_test.exs test/jido_flow/graph_identity_test.exs \
  test/jido_exec/validation_contract_test.exs --seed 0
```

The Choice probe ran with `MIX_ENV=test mix run --no-compile` from a temporary
file. It made no repository change. The two observed failures are stated in
the defect row and in the API reference.

Documentation checks passed:

- `mix format --check-formatted mix.exs` for the four navigation additions.
- `mix docs --warnings-as-errors` after correcting new-page link formatting.
- All 238 Markdown links: local guide paths/anchors and source paths at the
  cited Git commit. This is a path check, not an HTTP availability check.
- Rendered table checks: 31 tables in the reference and 4 in this review.
- Complete mapping: 36 distinct public entries and 42 distinct original IDs.
- `git diff --check` and a whitespace check on the new Markdown files.
- Hash comparison of prior modified files, excluding only the four added
  documentation-navigation lines in `mix.exs`.

The initial documentation review did not run the full default, property, fuzz,
authoring, load, system, mutation, or quality suites. The implementation checks
below are separate from that review evidence.


### Implementation checks

The Choice regression failed before the fix and passed after the fix. It checks
a matching and nonmatching option named `fallback`, with concurrency 1 and 4,
and the same results after reconstruction from a Runic build log.

Fresh checks on 2026-10-14 passed:

- Focused Choice, reconstruction, Map, Dispatch, and authoring checks: 44 tests.
- Default suite: 919 tests passed, 132 excluded.
- `mix test.all --cover --warnings-as-errors`: 1,051 passed
  (29 properties and 1,022 tests), with 95.13% coverage. All required fuzz
  cases completed. This includes authoring, property, fuzz, load, and system
  suites.
- `mix test.contracts`: 977 passed (29 properties and 948 tests),
  74 excluded; all 48 active obligations had passing test evidence.
- `mix quality`: format, compilation, Doctor, ExDoc, Credo, and Dialyzer
  passed. Doctor reported 100% documentation and specification coverage;
  Credo and Dialyzer reported no issues.

The full coverage check used local Runic commit
`cc21aa299c0010e9e97e6f5a88198e6309f55543`. Earlier coverage runs failed
because the compiled Runic dependency lacked the runnable-order callback
clause that was present in its source. A forced test dependency rebuild
restored that clause; the full coverage run then passed. No Runic source
change was made in this task.

Covenant remains optional. Normal tests still run in default CI. Mutation
checks were not run; saved survivor records do not prove the current source
has been checked again.


The checkpoint check also included the local Fact fix for improper lists and
its four regression tests. `mix quality` passed. The full
`mix test.all --cover --warnings-as-errors` run passed 1,055 tests
(29 properties and 1,026 tests), with 95.14% coverage and all required fuzz
cases completed.
