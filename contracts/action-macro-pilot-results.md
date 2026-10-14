# Action macro pilot results

The pilot ran on 2026-10-13 from the Jido Action worktree, based on
`release/v3` commit `d7358a32`. It used the local Covenant fork on
`feat/macro-mutation`, with changes on top of commit
`642ea797bf8637c7d6c1fbb763836ce996193221`.

## Result

Macro mutation works for `use Jido.Action`. The existing tests detected 11
of the 13 mutations in `__using__/1`. The other two retain unused schema
values in a private attribute and are equivalent for the public contract.
The generated metadata and validators were tested after the Action fixtures
and the contract test module were compiled against each mutation.

The full Action target also includes its runtime and compile-time helpers.
It found useful test gaps. Four new tests and stronger assertions in three
existing tests detected 19 more mutations. No Jido production file changed.

| Measure | Existing tests | After test changes |
| --- | ---: | ---: |
| Action tests | 38 | 42 |
| Mutations | 154 | 154 |
| Killed | 83 | 102 |
| Survived | 34 | 15 |
| Invalid | 37 | 37 |
| Timeouts | 0 | 0 |
| Mutation score | 70.9% | 87.2% |

The score excludes invalid mutations and includes all classified survivors.
Both runs used seed 0, one worker, and full kill credit. The mutation set was
unchanged between runs.

## Gaps found

| Gap | Mutations detected by the added assertions |
| --- | ---: |
| Accept names at the exact 256-byte limit, including multi-byte characters | 1 |
| Keep the output validation context and the context, module, and value in scalar-result errors | 4 |
| Reject nested process values and report precise map-key, tuple, list, and improper-list paths | 12 |
| Reject lazy schemas before their builders run | 2 |

These are test gaps. The existing implementation already passed the added
tests. This run did not identify a Jido product defect.

## Remaining survivors

The final mutation gate passed with 15 explicit classifications in
`jido_action/action.survivors.yml`:

- 3 equivalent changes: a redundant keyword-list predicate and two unused
  schema values retained in a private attribute.
- 6 changes in an unreachable escape-error fallback. Static-data validation
  rejects unsupported terms before that fallback.
- 6 changes to configuration descriptions or generated documentation text.
  These are outside the functional promises of this pilot. They are marked
  `unpromised`, not equivalent.

## Covenant implementation

`--macros` includes `defmacro`, `defmacrop`, and quoted code inside them.
It keeps the normal runtime mutation sites. `--recompile` names the compiled
callers that the tests require. Covenant compiles them in the supplied order,
then compiles the selected contract test files. The target modules are
restored after each mutation. Caller and test modules are restored from the
exact binaries used by the compiled baseline. New modules compiled in memory
are removed, including virtual source filenames and modules created before
a compilation failure.

The regression tests cover direct callers, transitive callers, private
macros, retained compile-time test values, repeated test source paths,
partial compilation, invalid source paths, and a caller compilation hang.
The existing watchdog stops a hang without kill credit. A caller compilation
failure is invalid and receives no test or obligation credit.

The design review found three Covenant defects. All three are fixed:

- Caller restoration used an older disk BEAM when it differed from the
  freshly compiled baseline. Covenant now keeps the baseline binaries.
- Cleanup used source filenames to identify generated modules. Covenant now
  records the loaded modules before each mutation and removes new modules
  compiled in memory. Prior in-memory modules and modules loaded from disk
  remain loaded.
- A macro defined in quoted output took the mutation scope from its provider.
  These sites now keep the enclosing provider macro as their function, so a
  function-level `covers` reference selects them.

Three regression tests failed against the previous implementation and passed
after the fixes. Further tests check disk module loading and the complete
runner flow for baseline restoration, helper creation, and partial compilation
failure. The macro test file now contains 11 tests.

Caller discovery is explicit. This mode does not claim that all callers in
a project were rebuilt. It still skips guard definitions, struct and exception
declarations, compiler attributes, documentation attributes, types, and quotes
outside macro definitions.

The fork also defines the matrix's obligation field on the Mutant struct.
This removes the Elixir 1.20 compiler warning about an undeclared struct key.
Five old CLI-summary tests were adjusted to accept both ExUnit summary formats.

## Validation

- Jido Action default suite: 758 passed, 120 excluded.
- Combined pilot: 111 unit tests and 4 properties passed, 1 fuzz test excluded.
- Contract checks: all 16 obligations passed; the static check passed.
- Error and Instruction mutation checks passed: 69 of 76 and 197 of 235
  mutations killed, with all survivors classified and no timeouts.
- Jido Action formatting, compilation with warnings as errors, and Credo passed.
- Covenant full suite on Elixir 1.20.4 / OTP 29: 468 passed.
- Covenant macro regressions: all 11 passed on Elixir 1.18 / OTP 27,
  Elixir 1.19 / OTP 28, and Elixir 1.20 / OTP 29.
- Covenant formatting and compilation with warnings as errors passed.
- Covenant's own contract check: all 98 obligations passed; the static check
  also passed.
- The repeated Action macro run retained all 154 mutation IDs and verdicts.
  It again killed 102 mutations, classified 15 survivors, and found 37 invalid
  mutations, with no timeouts. The score remains 87.2 percent.
- The consumer dependency log confirmed the local source at
  `/Users/mhostetler/Source/Jido/proj_jido_core/covenant`.

Logs for the repeated Jido checks use the `review-fixes-` prefix under
`tmp/covenant-pilot/`. Covenant validation logs use the `covenant-fixes-`
prefix in the same directory. The repeated Action matrix is saved as
`review-fixes-action-kill-matrix.json`. No Jido production file changed.

## Run it

The published Git pin still selects the original Covenant implementation.
Use the local fork for this macro command until its changes are published
and the pin is updated:

```sh
export COVENANT_PATH=../covenant
mix deps.get
JIDO_COVENANT_PILOT=1 mix covenant.check
JIDO_COVENANT_PILOT=1 mix covenant.mutate jido_action.action --macros \
  --recompile test/support/fixtures/action/definitions.ex --seed 0
```

Before and after matrices and logs are under `tmp/covenant-pilot/`, with
the `action-macro-` prefix. The final matrix is at
`tmp/covenant/mutate/jido_action.action/kill_matrix.json`. These outputs are
ignored by Git.
