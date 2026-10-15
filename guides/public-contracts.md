# Public Contract Register

This register links the public Jido Action contracts to their main test
evidence. It is a review aid. Public module documentation remains the API
source.

Tests declare contract IDs with tags such as `@tag contracts: ["EXEC-003"]`.
Keep an ID when its wording becomes more precise. Do not reuse a retired ID.

The Covenant column points to focused evidence within the 15 reviewed public
promise groups. Several entries share an obligation; no duplicate obligation
is required for the same assertion. Some groups need several obligations.
See the [contract review](public-api-contract-review.md) for the full mapping
and [API reference](public-api-reference.md) for the supported behavior.

Public register tags (`contracts:`) support property reports. Covenant tags
(`obligation:`) connect tests to focused requirements. Run `mix test.contracts`
to check them and write `test/contracts/coverage.json`. A passing tag is a
minimum evidence check, not proof of complete API, branch, or matrix coverage.
Covenant remains optional and does not run in default CI.

## Actions, Targets, And Instructions

| ID | Public promise | Covenant obligation | Main evidence |
| --- | --- | --- | --- |
| ACT-001 | Input validation runs before the Action callback. | `jido_action.boundary.I1` | `test/property/action/boundary_contract_test.exs`, `test/jido_exec/node/action_test.exs` |
| ACT-002 | Callback exceptions, throws, exits, invalid returns, and returned errors become structured Jido errors. | `jido_action.boundary.I2` | `test/property/action/boundary_contract_test.exs`, `test/jido_exec/node/action_test.exs` |
| ACT-003 | Output validation runs after the Action callback. | `jido_action.boundary.I3` | `test/property/action/boundary_contract_test.exs`, `test/jido_exec/node/action_test.exs` |
| ACT-004 | Intentional non-map success uses an Output envelope, and effect requests are proper lists. | `jido_action.boundary.I4` | `test/property/action/boundary_contract_test.exs` |
| ACT-005 | An inline Step becomes an ordinary Action and keeps access to its owner's lexical helpers. | `jido_action.inline.I2` | `test/property/flow/inline_contract_test.exs`, `test/jido_action/inline_host_test.exs` |
| TARGET-001 | Resolution preserves each supported target and kind and rejects invalid descriptors. | `jido_action.instruction.I5` | `test/property/instruction/target_contract_test.exs`, `test/jido_instruction/target_test.exs` |
| INS-001 | An Instruction carries call data and uses shallow params and context overrides without treating metadata as execution policy. | `jido_action.instruction.I4` | `test/property/instruction/call_contract_test.exs`, `test/jido_instruction/` |
| ERROR-001 | Error maps preserve their documented type, details, and retry policy and omit top-level stacktraces. | `jido_action.errors.I3` | `test/property/action/error_contract_test.exs`, `test/jido_action/error_test.exs` |

## Expressions

| ID | Public promise | Covenant obligation | Main evidence |
| --- | --- | --- | --- |
| EXPR-001 | Supported expression operations follow documented Elixir result and short-circuit rules. | `jido_action.expression.I1` | `test/property/expression/expression_contract_test.exs`, `test/jido_flow/expr_test.exs` |
| EXPR-002 | Expression construction checks operator and arity; parsing, validation, traversal, and evaluation enforce their documented limits. | `jido_action.expression.I4` | `test/property/expression/expression_contract_test.exs` |

## Flow Definition And Storage

| ID | Public promise | Covenant obligation | Main evidence |
| --- | --- | --- | --- |
| FLOW-001 | The DSL, map definitions, and Codec produce the same canonical Flow model. | `jido_action.flow.I7` | `test/property/flow/graph_contract_test.exs`, `test/authoring/` |
| FLOW-002 | References and explicit needs create dependencies. Source order does not create a dependency. | `jido_action.flow.I8` | `test/property/flow/graph_contract_test.exs`, `test/jido_flow/canonical_data_test.exs` |
| FLOW-003 | Invalid graph definitions return structured validation errors. | `jido_action.flow.I8` | `test/property/flow/validation_contract_test.exs`, `test/authoring/rejections_test.exs` |
| FLOW-004 | Validation and inspection do not run Action work. | `jido_action.flow.I9` | `test/property/flow/validation_contract_test.exs`, `test/jido_flow/` |
| FLOW-005 | Semantic identity distinguishes references from literal data and survives a Codec round trip. | `jido_action.flow.I10` | `test/property/flow/validation_contract_test.exs`, `test/jido_flow/graph_identity_test.exs` |
| FLOW-006 | Host extensions lower to ordinary canonical declarations. | `jido_action.flow.I11` | `test/property/flow/inline_contract_test.exs`, `test/jido_flow/` |
| STORE-001 | The JSON document version preserves canonical Flow meaning and deterministic stored-map encoding. | `jido_action.codec.I5` | `test/property/storage/codec_contract_test.exs`, `test/jido_flow/codec_test.exs` |
| STORE-002 | Stored identifiers resolve through a trusted Registry without creating atoms from unknown identifiers. | `jido_action.codec.I6` | `test/property/storage/codec_contract_test.exs`, `test/jido_flow/codec_test.exs` |
| STORE-003 | Malformed or oversized stored documents return structured errors. | `jido_action.codec.I7` | `test/property/storage/codec_contract_test.exs`, `test/jido_flow/codec_test.exs` |

## Execution And Effects

| ID | Public promise | Covenant obligation | Main evidence |
| --- | --- | --- | --- |
| EXEC-001 | An Action compiles to an executable Runic workflow without running its work. | `jido_action.boundary.I5` | `test/jido_exec/api_test.exs`, `test/property/execution/exec_contract_test.exs` |
| EXEC-002 | Flow compilation and Runic reconstruction preserve executable meaning. | `jido_action.boundary.I5` | `test/jido_exec/compiler_test.exs`, `test/jido_exec/flow_execution_test.exs` |
| EXEC-003 | Choice, Map, Reduce, Iterate, nested Flow, and Dispatch keep their authored semantics. | `jido_action.execution.I17` | `test/property/flow/component_contract_test.exs`, `test/property/flow/mixed_contract_test.exs`, `test/property/execution/runner_fuzz_test.exs` |
| EXEC-004 | Failure stops new work according to Runic policy, while work that is already admitted can finish. | `jido_action.execution.I18` | `test/property/flow/iterate_fuzz_test.exs`, `test/jido_exec/runner/policy_test.exs`, `test/property/execution/runner_fuzz_test.exs` |
| EXEC-005 | One concurrency policy applies to nested and collection work, while Reduce and Iterate remain serial. | `jido_action.execution.I18` | `test/property/flow/iterate_fuzz_test.exs`, `test/jido_exec/runner/policy_test.exs`, `test/property/execution/runner_fuzz_test.exs` |
| EXEC-006 | Manual managed execution dispatches one Runic scheduler unit per step and returns inspectable Runic workflow state. | `jido_action.execution.I21` | `test/jido_exec/runner/stepwise_test.exs`, Runic stepwise Runner tests, `test/property/execution/runner_fuzz_test.exs` |
| EXEC-007 | Jido emits bounded Action and immediate Flow telemetry. Timeout or process death can prevent stop events. Runic owns managed runtime telemetry. | `jido_action.execution.I23` | `test/jido_exec/telemetry_test.exs`, Runic Runner telemetry tests, `test/property/execution/runner_fuzz_test.exs` |
| EFFECT-001 | Effects preserve dependency, component, nested, and collection order and request multiplicity. | `jido_action.execution.I19` | `test/property/flow/component_contract_test.exs`, `test/examples/action_effects_test.exs` |
| EFFECT-002 | Failed Action output does not expose an executable effect batch. | `jido_action.boundary.I3` | `test/property/action/boundary_contract_test.exs`, `test/property/flow/component_contract_test.exs` |

## Durability

| ID | Public promise | Covenant obligation | Main evidence |
| --- | --- | --- | --- |
| DURABLE-001 | Recovery resumes after acknowledged stored progress; the ten-Action case is one example. | `jido_action.execution.I22` | `test/jido_exec/runner/durability_test.exs` |
| DURABLE-002 | Acknowledged stored completed work is preserved during recovery. Work after the last acknowledged checkpoint can repeat. | `jido_action.execution.I22` | `test/jido_exec/runner/durability_test.exs`, Runic Runner recovery tests, `test/property/execution/runner_fuzz_test.exs` |
| DURABLE-003 | Map, Iterate, nested Flow, and Dispatch progress survive recovery. | `jido_action.execution.I22` | `test/jido_exec/runner/durability_test.exs`, `test/property/execution/runner_fuzz_test.exs` |
| DURABLE-004 | Runtime state uses the Runic Store and event stream. Jido has no checkpoint format. | `jido_action.execution.I22` | `test/jido_exec/runner/durability_test.exs`, `test/property/execution/runner_fuzz_test.exs` |
| DURABLE-005 | Logical effect identity is stable across retry attempts with fixed execution, activation, output, and effect index. | `jido_action.execution.I24` | `test/jido_exec/runner/policy_test.exs`, `test/property/execution/runner_fuzz_test.exs` |

## Security And Limits

| ID | Public promise | Covenant obligation | Main evidence |
| --- | --- | --- | --- |
| SECURITY-001 | Codec Registry lookup is the stored identifier-to-module boundary. | `jido_action.codec.I6` | `test/jido_flow/codec_test.exs` |
| SECURITY-002 | Managed execution rejects process-local params and context before start. | `jido_action.boundary.I10` | `test/jido_exec/portable_test.exs`, `test/property/execution/runner_fuzz_test.exs` |
| SECURITY-003 | Malformed options and unsupported executable values return structured errors. | `jido_action.boundary.I6` | Exec and authoring rejection tests |

## Fuzz Cases

These are the required measured fuzz IDs. `mix test.fuzz` and `mix test.all`
reject a report that omits any ID. Bounds limit new generation; fixed examples
and saved replays run separately. Contract tags are an evidence index, not a
claim of complete API or branch coverage.

| Fuzz ID | Samples | Input bounds and main checks |
| --- | ---: | --- |
| `action_boundaries` | 250 | 30 output items; validation, callback failures, envelopes, effects |
| `authoring_equivalence` | 100 | 8 source nodes; DSL, inline, and extension equivalence |
| `codec_mutations` | 300 | Invalid fields; depth, width, and total-node limits |
| `codec_portability` | 300 | Portable trees; every component kind; version 1 |
| `dispatch_chains` | 60 | 6 links; Action/Flow terminals; errors and timeout; three current modes |
| `expression_trees` | 1,000 | Numeric depth 5, Boolean depth 2; independent operations and limits |
| `graph_rejections` | 300 | 12 nodes; invalid graph forms and inert inspection |
| `graph_semantics` | 600 | 12 nodes; independent arithmetic and canonical effects |
| `instruction_targets` | 500 | Optional key sets; shallow overrides and all target forms |
| `iterate_state` | 200 | 12 iterations; serial/concurrent runs; state and body faults |
| `mixed_components` | 300 | 10 items; Choice, Map, Reduce, and nested Flow |
| `nested_runner_failures` | 100 | 8 items; limits 1–3; nested failure, admission, and cleanup |
| `runner_histories` | 80 | 2–6 calls; up to 4 commands; manual steps, checkpoint, resume, continue |
| `runner_schedules` | 100 | 8 items; limits 1–4; completion order, cancellation, stop, cleanup |
| `runner_telemetry` | 60 | 1–4 attempts; retry identity, bounded metadata, immediate/managed events |

The graph and mixed cases also have short measured variants of 60 and 30
samples. See [the property test guide](https://github.com/agentjido/jido_action/blob/release/v3/test/property/README.md) for selection,
replay, ownership, and remaining limits.

## Verification Suites

Run the complete package checks after an execution or compiler change:

```text
mix test
mix test.authoring
mix test.property
mix test.system
mix test.load
mix test.fuzz
mix test.all
mix quality
```

Manual benchmark timing is outside correctness acceptance. See
[Execution Benchmarks](benchmarks.md).
