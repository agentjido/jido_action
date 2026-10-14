# Instruction Covenant trial results

The trial ran on 2026-10-13 with Elixir 1.20.4 and Erlang/OTP 29. It used
Covenant version `0.1.0`, pinned to
`642ea797bf8637c7d6c1fbb763836ce996193221`.
The mutation target was `Jido.Instruction`. Each run used seed 0 and one worker.

## Result

The trial found test gaps. It found no incorrect Instruction behavior in the
tested cases. The implementation passed the stronger tests without a production
code change. Four unit tests were added. Existing assertions were strengthened
in the two Instruction unit test files. The property assertions were retained.

| Measure | Existing assertions | Strengthened assertions |
| --- | --- | --- |
| Tests executed | 48 unit tests and 3 property tests | 52 unit tests and 3 property tests |
| Passing Instruction obligations | 7 of 7 | 7 of 7 |
| Mutations generated | 235 | 235 |
| Mutations detected | 172 | 197 |
| Surviving mutations | 50 | 25 |
| Invalid mutations | 13 | 13 |
| Timed-out mutations | 0 | 0 |
| Mutation score | 77.5% | 88.7% |
| Mutation check exit status | 1: unclassified survivors | 0: all remaining survivors classified |

The score excludes invalid mutations. The generated mutations were identical
before and after the test changes. One long fuzz test was excluded in both
runs. Covenant reports 52 and 56 baseline entries; those counts include the
excluded test. The executed counts above come from the ExUnit results.

## Useful gaps

| Gap | Evidence from mutation testing | Test change |
| --- | --- | --- |
| Callback tests checked missing run/2 and flow/0, but not missing validators. | Removing validate_params/1 or validate_output/1 checks survived: `m073`, `m074`. | Reuse the existing missing-validator fixtures in both bind and validate tests. |
| Template rejection did not cover non-Instructions or invalid metadata. | Removing metadata rejection or returning nil for a non-Instruction survived: `m129`, `m143`. | Extend the rejection matrix with nil, a plain map, invalid metadata, and nil targets. Require the original template and reason in the error details. |
| Defensive validation of an already resolved Instruction had no malformed-value cases. | Invalid kinds and targets could be accepted, raise, return nil, or lose error fields: `m056`, `m059`, `m062`, `m063`, `m079`–`m082`. | Add a focused test of the internal resolved-value rule with invalid kinds, nil, a binary target, and a Flow under an Action kind. |
| There was no unavailable module case. | Removing the module compilation failure branch survived: `m149`. | Check resolve, new, bind, and validate against a unique module with no beam file. |
| Callback validation always received loaded modules in the tests. | Removing Code.ensure_loaded/1 survived: `m172`. | Compile a unique target fixture, save its beam file, unload it, and verify that resolved validation loads it without executing its callbacks. |
| Several diagnostic fields and messages were not checked. | Empty messages and removed value, template, or expected_format fields survived. | Require the rejected values, useful nonempty messages, and format guidance. Existing stable reason and target assertions remain. |

The second run detected all 25 mutations associated with these gaps.

A further test changes a unique target module from Action behavior to Flow
behavior. It verifies that resolution refreshes the retained kind, an old
Action template is rejected, and a Flow template binds successfully. All
callbacks raise if called, so the test also checks that resolution, validation,
and binding do not execute them. The existing tests checked a manually stale
kind but did not perform an actual reload.

The target test module runs synchronously because its unloaded-module test
changes the VM code path. Each dynamic module and code path is removed during
test cleanup.

## Remaining survivors

All 25 survivors have individual entries in
`jido_action/instruction.survivors.yml`:

| Classification | Count | Reason |
| --- | --- | --- |
| Equivalent behavior | 17 | Removed assignments equal current struct defaults; intermediate retained kinds are replaced by current classification; private schema descriptions and its coercion option do not affect the runtime API; two exception guards and a list guard are redundant for current helper results. |
| Currently unreachable fallback code | 6 | new and resolve always return exception structs on error. The raising wrappers' fallback for a non-exception error is not reached. |
| Outside the runtime mutation contract | 2 | Removing Action or Flow from the private schema changes a generated type declaration. The runtime target classifier remains correct. The hot-swapped runtime tests do not observe this compiler metadata. |

The two type mutations are classified as `unpromised` for this runtime trial.
They are a coverage limit. The public type declarations still matter, but a
passing runtime mutation check does not prove their completeness. They were
not classified as equivalent behavior. The production type declarations were
retained.

The six unreachable fallback mutations identify possible future cleanup.
The fallback code was retained. Tests were not added that force helpers to
return unsupported error shapes only to improve the score.

## Validation

- The combined Error and Instruction pilot passed 69 unit tests and four
  property tests, with one long fuzz test excluded.
- The fresh contract results passed all 12 obligations: five Error obligations
  and seven Instruction obligations.
- The Instruction mutation check passed with 197 detected mutations and 25
  reviewed survivors. There were no timeouts or unclassified survivors.
- The existing Jido property report finished with a passed outcome and
  evidence for `ERROR-001`, `INS-001`, `TARGET-001`, and `FLOW-004`. It had
  no unknown contract IDs or invalid case IDs.
- The full default package suite passed 798 tests, with 120 excluded by the
  existing suite selection.
- Package formatting, compilation with warnings treated as errors, lint,
  and static contract checks passed.

Other local execution and Map work was present during the trial. It was left
unchanged. This report records the tested working tree; it does not claim a
clean committed revision.

## Reproduce and review

Use the commands in [the trial README](README.md). To run only the Instruction
tests:

```sh
mix test test/jido_instruction test/property/instruction --include property --seed 0
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.instruction --seed 0
```

Code changes for this extension are in:

- `config/config.exs`: include the four Instruction test files.
- `test/jido_instruction/instruction_test.exs`: contract tags and stronger
  template, binding, and constructor error assertions.
- `test/jido_instruction/target_test.exs`: contract tags, missing validator
  cases, stronger errors, unavailable and unloaded modules, malformed resolved
  values, and a real module reload.
- `test/property/instruction/call_contract_test.exs`: contract tags only.
- `test/property/instruction/target_contract_test.exs`: contract tags only.

The before and after logs and matrices are under
`tmp/covenant-instruction-pilot/`. The current matrix is at
`tmp/covenant/mutate/jido_action.instruction/kill_matrix.json`.
These files are ignored by Git. This report retains the measured results.
