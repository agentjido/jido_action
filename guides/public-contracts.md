# Public Contract Register

This register links the public Jido Action contracts to their main test
evidence. It is a review aid. Public module documentation remains the API
source.

Tests declare contract IDs with tags such as `@tag contracts: ["EXEC-003"]`.
Keep an ID when its wording becomes more precise. Do not reuse a retired ID.

## Actions, Targets, And Instructions

| ID | Public promise | Main evidence |
| --- | --- | --- |
| ACT-001 | Input validation runs before the Action callback. | `test/property/action/boundary_contract_test.exs`, `test/jido_exec/node/action_test.exs` |
| ACT-002 | Callback exceptions, throws, exits, invalid returns, and returned errors become structured Jido errors. | `test/property/action/boundary_contract_test.exs`, `test/jido_exec/node/action_test.exs` |
| ACT-003 | Output validation runs after the Action callback. | `test/property/action/boundary_contract_test.exs`, `test/jido_exec/node/action_test.exs` |
| ACT-004 | Intentional non-map success uses an Output envelope, and effect requests are proper lists. | `test/property/action/boundary_contract_test.exs` |
| ACT-005 | An inline Step becomes an ordinary Action and keeps access to its owner's lexical helpers. | `test/property/flow/inline_contract_test.exs`, `test/jido_action/inline_host_test.exs` |
| TARGET-001 | Resolution preserves each supported target and kind and rejects invalid descriptors. | `test/property/instruction/target_contract_test.exs`, `test/jido_instruction/target_test.exs` |
| INS-001 | An Instruction carries call data and uses shallow params and context overrides without treating metadata as execution policy. | `test/property/instruction/call_contract_test.exs`, `test/jido_instruction/` |
| ERROR-001 | Error maps preserve their documented type, details, and retry policy and omit top-level stacktraces. | `test/property/action/error_contract_test.exs` |

## Expressions

| ID | Public promise | Main evidence |
| --- | --- | --- |
| EXPR-001 | Supported expression operations follow documented Elixir result and short-circuit rules. | `test/property/expression/expression_contract_test.exs`, `test/jido_flow/expr_test.exs` |
| EXPR-002 | Expression constructors and public limits reject unsupported or oversized input. | `test/property/expression/expression_contract_test.exs` |

## Flow Definition And Storage

| ID | Public promise | Main evidence |
| --- | --- | --- |
| FLOW-001 | The DSL, map definitions, and Codec produce the same canonical Flow model. | `test/property/flow/graph_contract_test.exs`, `test/authoring/` |
| FLOW-002 | References and explicit needs create dependencies. Source order does not create a dependency. | `test/property/flow/graph_contract_test.exs`, `test/jido_flow/canonical_data_test.exs` |
| FLOW-003 | Invalid graph definitions return structured validation errors. | `test/property/flow/validation_contract_test.exs`, `test/authoring/rejections_test.exs` |
| FLOW-004 | Validation and inspection do not run Action work. | `test/property/flow/validation_contract_test.exs`, `test/jido_flow/` |
| FLOW-005 | Semantic identity distinguishes references from literal data and survives a Codec round trip. | `test/property/flow/validation_contract_test.exs`, `test/jido_flow/graph_identity_test.exs` |
| FLOW-006 | Host extensions lower to ordinary canonical declarations. | `test/property/flow/inline_contract_test.exs`, `test/jido_flow/` |
| STORE-001 | Supported JSON versions preserve canonical Flow meaning and deterministic stored-map encoding. | `test/property/storage/codec_contract_test.exs`, `test/jido_flow/codec_test.exs` |
| STORE-002 | Stored identifiers resolve through a trusted Registry without creating atoms from unknown identifiers. | `test/property/storage/codec_contract_test.exs`, `test/jido_flow/codec_test.exs` |
| STORE-003 | Malformed or oversized stored documents return structured errors. | `test/property/storage/codec_contract_test.exs`, `test/jido_flow/codec_test.exs` |

## Execution And Effects

| ID | Public promise | Main evidence |
| --- | --- | --- |
| EXEC-001 | One Action executes as a one-node Runic workflow. | `test/jido_exec/api_test.exs`, `test/property/execution/exec_contract_test.exs` |
| EXEC-002 | A Flow compiles to executable Runic components and edges. | `test/jido_exec/compiler_test.exs`, `test/jido_exec/flow_execution_test.exs` |
| EXEC-003 | Choice, Map, Reduce, Iterate, nested Flow, and Dispatch keep their authored semantics. | `test/property/flow/component_contract_test.exs`, `test/property/flow/mixed_contract_test.exs` |
| EXEC-004 | Failure stops new work according to Runic policy, while work that is already admitted can finish. | `test/property/flow/iterate_fuzz_test.exs`, `test/jido_exec/runner/policy_test.exs` |
| EXEC-005 | One concurrency policy applies to nested and collection work, while Reduce and Iterate remain serial. | `test/property/flow/iterate_fuzz_test.exs`, `test/jido_exec/runner/policy_test.exs` |
| EFFECT-001 | Effects preserve dependency, component, nested, and collection order and request multiplicity. | `test/property/flow/component_contract_test.exs`, `test/examples/action_effects_test.exs` |
| EFFECT-002 | Failed Action output does not expose an executable effect batch. | `test/property/action/boundary_contract_test.exs`, `test/property/flow/component_contract_test.exs` |

## Durability

| ID | Public promise | Main evidence |
| --- | --- | --- |
| DURABLE-001 | A ten-Action Flow can stop after Action 5 and resume at Action 6. | `test/jido_exec/runner/durability_test.exs` |
| DURABLE-002 | Completed work does not run again after Runic Runner recovery. | `test/jido_exec/runner/durability_test.exs`, Runic Runner recovery tests |
| DURABLE-003 | Map, Iterate, nested Flow, and Dispatch progress survive recovery. | `test/jido_exec/runner/durability_test.exs` |
| DURABLE-004 | Runtime state uses the Runic Store and event stream. Jido has no checkpoint format. | `test/jido_exec/runner/durability_test.exs` |
| DURABLE-005 | Logical effect identity is stable across retry attempts. | `test/jido_exec/runner/policy_test.exs` |

## Security And Limits

| ID | Public promise | Main evidence |
| --- | --- | --- |
| SECURITY-001 | Codec Registry lookup is the stored identifier-to-module boundary. | `test/jido_flow/codec_test.exs` |
| SECURITY-002 | Managed execution rejects process-local params and context before start. | `test/jido_exec/portable_test.exs` |
| SECURITY-003 | Malformed options and unsupported executable values return structured errors. | Exec and authoring rejection tests |

## Verification Suites

Run the complete package checks after an execution or compiler change:

```text
mix test
mix test.authoring
mix test.property
mix test.system
mix test.load
mix quality
```

Manual benchmark timing is outside correctness acceptance. See
[Execution Benchmarks](benchmarks.md).
