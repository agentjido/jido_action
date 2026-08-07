# V3 Spike Non-Flow Review Tracker

## Scope

This tracker covers the non-Flow findings from the review of the `v3-spike`
branch at `9b594e2`. It does not cover `Jido.Flow` files or Flow-only behavior in
`Jido.Exec`.

Each finding must use this process:

1. Add or tighten one focused test that reproduces the problem.
2. Confirm that the focused test fails for the expected reason.
3. Make the smallest code change that corrects the problem.
4. Run the focused tests and the related non-Flow test group.
5. Mark the finding as done in this tracker.
6. Create one conventional commit for the finding.

The final verification must run all non-Flow tests and the full test suite.

## Findings

| ID | Priority | Finding | Focused verification | Status | Commit subject |
| --- | --- | --- | --- | --- | --- |
| F01 | P1 | Open validation can skip Zoi checks or reject valid input. | Generic maps, coerced keys, string field keys, and struct input | Done | `fix(validation): preserve zoi input semantics` |
| F02 | P1 | Validator failures can escape `Jido.Exec.run/4`. | Invalid validator returns, raised validators, and telemetry status | Done | `fix(exec): normalize validator failures` |
| F03 | P1 | Unknown action options can silently disable validation. | Compile an action with an unknown option | Done | `fix(action): reject unknown configuration options` |
| F04 | P1 | The action generator has three independent blockers. | Parse the positional value and inspect generated source | Done | `fix(generator): generate action modules correctly` |
| F05 | P1 | Error JSON encoding can fail on invalid UTF-8 binary data. | Encode invalid binary messages, values, and keys | Done | `fix(error): encode invalid utf8 safely` |
| F06 | P2 | Direct action output validation accepts malformed output envelopes. | Validate a malformed batch envelope through an action | Done | `fix(action): validate output envelopes directly` |
| F07 | P2 | Raw action results can bypass the required output envelope. | Run an action that returns a scalar | Done | `fix(exec): require envelopes for raw outputs` |
| F08 | P2 | `Jido.Exec` can lose valid third tuple elements. | Preserve success and error extras, including `:none` | Done | `fix(exec): preserve direct action extras` |
| F09 | P2 | Common schema option forms do not compile. | Compile schema variables and give dynamic closure schemas a clear inline-declaration error | Done | `fix(action): handle dynamic schema storage` |
| F10 | P2 | Open validation deletes unspecified nested or wrapped fields. | Preserve nested fields and fields under wrappers | Done | `fix(validation): preserve nested unknown fields` |
| F11 | P2 | `Jido.Instruction.new/1` can raise for malformed list input. | Call the non-bang constructor with a malformed list | Done | `fix(instruction): reject malformed list attributes` |
| F12 | P2 | Invalid instruction data is marked as retryable. | Normalize an invalid params or context error | Done | `fix(instruction): classify invalid call frames` |
| F13 | P2 | The public retry APIs can return different decisions. | Compare aliases and internal error hints | Done | `fix(error): align retry classification` |
| F14 | P2 | Batch output accepts improper lists. | Build a batch from an improper list | Done | `fix(output): reject improper batch lists` |
| F15 | P2 | Dynamic action options are evaluated three times. | Count calls to a dynamic option provider | Done | `fix(action): evaluate dynamic options once` |

## Final Verification

Completed on 2026-08-07:

- [x] All findings are marked `Done`.
- [x] Each finding has one fix commit.
- [x] All focused non-Flow tests pass: 163 tests.
- [x] The full test suite passes: 413 tests, including one property test.
- [x] `mix compile --warnings-as-errors` passes.
- [x] `mix format --check-formatted` passes.
- [x] The worktree is clean after the verification record commit.
