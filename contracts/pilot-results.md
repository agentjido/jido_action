# Covenant trial results

The trial ran on 2026-10-13 with Elixir 1.20.4 and Erlang/OTP 29. Covenant
was pinned to `642ea797bf8637c7d6c1fbb763836ce996193221`, version `0.1.0`.
Both mutation runs used seed 0 and one worker. The targets were
`Jido.Action.Error` and `Jido.Action.Error.Internal.UnknownError`.

## Result

Covenant found useful gaps in the existing tests. The production code did
not need a change. Three existing unit tests were strengthened, and one
unit test was added. The existing property test retained its assertions
and its `ERROR-001` tags.

| Measure | Existing assertions | Strengthened assertions |
| --- | --- | --- |
| Tests executed | 16 unit tests and 1 property test | 17 unit tests and 1 property test |
| Passing obligations | 5 of 5 | 5 of 5 |
| Mutations generated | 76 | 76 |
| Mutations detected | 59 | 69 |
| Surviving mutations | 11 | 1 |
| Invalid mutations | 6 | 6 |
| Timed-out mutations | 0 | 0 |
| Mutation score | 84.3% | 98.6% |
| Mutation check exit status | 1: 11 unclassified survivors | 0: one documented equivalent survivor |

The score excludes invalid mutations. It includes the equivalent survivor.
The six invalid mutations remove a bound variable from a pattern and fail
compilation. They supply no evidence for test strength.

## Useful gaps

| Gap | Mutations first missed | Test change |
| --- | --- | --- |
| Unknown-error messages were checked mainly for their type. `Exception.message/1` can return a diagnostic string when the message callback returns an invalid result. That string passed the old binary check. | `m002`, `m004`, `m006`, `m009`, `m010` | Check the exact complete error map for a stored message, binary reason, atom reason, integer reason, and tuple reason. |
| Three-element retry tuples had no positive retry case. | `m034` | Check both tuple forms with permitted and rejected retry cases. |
| Some retry checks used `refute`, which accepts both false and nil. The API promises a Boolean result. | `m042`, `m056` | Require exactly false for unknown errors and unsupported values. |
| Only Boolean direct retry hints were covered. Removing the Boolean guards left non-Boolean results undetected. | `m045`, `m051` | Check nil, integer, binary, atom, list, and map hints for both execution and timeout errors. |

The second full mutation run detected all ten mutations in this table.

## Equivalent survivor

`m062` removes the list guard from `normalize_constructor_details/1`.
The preceding clause already handles plain maps. `Keyword.keyword?/1`
rejects non-list and non-keyword inputs, so the mutated clause still returns
an empty map for unsupported containers. Keyword lists still use the same
conversion. The survivor is documented in `jido_action/errors.survivors.yml`.
The production guard was retained.

## Integration observations

- Covenant supports the existing StreamData property test. Its result was
  included in both mutation baselines.
- `JIDO_COVENANT_PILOT=1` enables the property test. Normal test exclusions
  are unchanged.
- `covenant.check` selects its own formatter list. To retain both reports,
  run the selected tests with the three explicit formatters shown below,
  then use `covenant.check --no-run` on those fresh results. The test helper
  skips Jido report setup under the trial option, so Covenant checks and
  mutation workers cannot reset a completed property report.
- Setting `sibling_dir: false` caused Covenant's mutation worker to raise
  `BadBooleanError` in `Covenant.find_root/4`. The trial uses the default
  sibling directory setting instead. There is no sibling contract directory
  in this package.
- Covenant emitted an Elixir 1.20 compiler warning for access to an undeclared
  `obligations` struct key in `Covenant.Mutate.Matrix.to_map/1`. The contract
  and mutation tasks completed successfully. No dependency source was changed.
- Tests for Splode classes and direct JSON encoding remain useful, although
  their mutations have no unique test credit. Covenant skips the `use`
  declarations and generated code that establish much of this behavior.
- The combined property test names three obligations. Its mutation credit is
  therefore shared between those obligations; it does not identify the exact
  assertion that failed.

## Reproduce

Run from the `jido_action` package root:

```sh
mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
JIDO_COVENANT_PILOT=1 mix covenant.check
mix test test/jido_action/error_test.exs test/property/action/error_contract_test.exs \
  --include property --seed 0 \
  --formatter ExUnit.CLIFormatter \
  --formatter JidoActionTest.Property.Report \
  --formatter Covenant.Formatter
mix covenant.check --no-run
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.errors --seed 0
mix format --check-formatted
mix test --warnings-as-errors
```

## Package validation

- The final native contract check passed all five obligations with 17 unit
  tests and one property test.
- The static contract check passed all five obligations.
- The final mutation check passed with 69 detected mutations, one documented
  equivalent survivor, six invalid mutations, and no timeouts. The generated
  mutation set was identical before and after the test changes.
- The combined formatter run produced a finished, passed Jido property report
  for `ERROR-001`, with no unknown contract IDs or invalid case IDs. Its bytes
  remained unchanged after the final native contract and mutation checks.
- The final package compile check passed with warnings treated as errors.
  The lint check and the format check for all trial files passed.
- An earlier full default test run passed 784 tests. During final validation,
  another local edit added native Batch assertions to
  `test/jido_exec/node/map_test.exs`. The later full run passed 784 of 787
  tests and failed three new Batch assertions because the requested component
  was nil. Those three failures also occurred when that file ran alone.
  The full format check found a missing blank line in the same local edit.
  The separate Map work was left unchanged.

The local before and after logs and JSON reports are in
`tmp/covenant-pilot/`. The current mutation matrix is in
`tmp/covenant/mutate/jido_action.errors/kill_matrix.json`. These temporary
files are ignored by Git. This report retains the findings and counts.

## Recommendation

Keep this trial limited to Action errors for now. The mutation check found
gaps that a 100% obligation-coverage result did not reveal. Try Instructions
next if the contract files and survivor review remain easy to maintain.
Retain the normal authoring, property, and integration suites when you extend
the trial. A passing mutation check covers only its supported operators and
the tests selected for the run.
