# Flow authoring test backlog

This file tracks end-to-end authoring tests for `Jido.Flow`. It does not replace
the focused rules in `test/jido_flow/` or the Exec runtime tests in
`test/jido_exec/`. Run this opt-in suite with `mix test.authoring` from the
`jido_action` package.

## Test contract

- Use source fixtures under `test/authoring/support/`. Compile them only when
  the authoring suite runs. Keep invalid source out of normal compilation.
- For each component, build one representative Flow through the module DSL,
  direct constructors, Builder, and stored JSON. Compare canonical Flow data
  and the final result. Use a trusted Registry for stored JSON.
- Test other edge cases at the public boundary that owns them. Do not repeat
  every case in all four forms. If a form must reject a case, assert that
  rejection instead of forcing parity.
- Check exact Action calls or explicit messages when work order matters. Check
  that validation, inspection, and decode do not run Action work.
- Use explicit ready/release messages, monitors, and completion barriers. Do
  not use sleeps or elapsed time to prove order or cleanup.
- Keep failures as small, replayable source or JSON fixtures. Assert the error
  type and useful details. For DSL errors, check the source file and line.
- Keep load, resource burn-in, and broad runtime fault tests in their separate
  suites. Authoring tests must stay small enough to explain one user contract.

## Current coverage

These checks exist in the opt-in authoring suite. The status here describes
source coverage; it is not a fresh test result. `components_test.exs` and
`boundaries_test.exs` hold the newer component and boundary examples.

- [x] A named Action and a two-Step Flow run from source.
- [x] One Step graph has equal DSL, direct, Builder, and JSON forms.
- [x] All 24 declaration orders for a four-Step graph keep equal data and
  results across the four forms, full run, and step-wise run.
- [x] Forward references, `needs`, unusual component names, nested paths, and
  literal `"$ref"` and `"$expr"` keys work in a combined graph.
- [x] Choice first-match order, fallback, unselected-branch dependency, and
  selected-route failure work in one source example.
- [x] A child Flow receives context and reports child-input and leaf-error
  paths.
- [x] Missing output, duplicate names, unknown needs, and cycles fail at the
  source boundary. The last three also fail through direct, Builder, and JSON.
- [x] Stored JSON rejects an Action identifier outside the trusted Registry
  without creating an atom.
- [x] Map, Reduce, Iterate, Subflow, Choice, and Dispatch have source examples
  that agree with direct, Builder, and JSON forms on valid results.
- [x] A controlled Map run releases repeated items in reverse order but keeps
  result order, item indexes, and distinct item IDs.
- [x] Hostile source and direct Flows reject wrong target kinds, local reference
  scope errors, a non-Boolean Choice condition, invalid Iterate State, and
  invalid Dispatch graphs before unrelated Action work.
- [x] Stored Flow depth, collection width, and total-node limits reject bounded
  hostile documents. An invalid UTF-8 name is also rejected.

## P0: complete the component surface

Give each missing component a small source fixture. Add one cross-form parity
test per component. Then add the named edge cases as source-level examples.

### Map

- [x] Author Map in keyword and block DSL forms; compare it with direct,
  Builder, and JSON data and results.
- [x] Empty input returns an empty, map-shaped output and calls no item Action.
- [x] Repeated values and concurrent item completion retain input order. Check
  `item()`, `item_index()`, and `item_id()` with exact item identities.
- [x] Compare `:fail_fast` with `:collect_errors` on one bad item. Check which
  work starts, tagged result order, and the public error map.
- [x] Reject a Flow module or an out-of-scope reference in the Map Action slot
  or parameter map before work starts.

### Reduce

- [x] Author Reduce in DSL, direct, Builder, and JSON forms.
- [x] Empty input returns the initial accumulator and calls no body Action.
- [x] Use a non-associative fold to prove serial source order, including
  repeated items. Check `item()` and `accumulator()` values at each call.
- [x] A body failure stops the fold with the authored Reduce path. No later
  item runs.
- [x] Reject invalid initial data, an invalid accumulator reference, and a
  Flow module in the Action slot at the correct boundary.

### Iterate

- [x] Author fixed `repeat` and bounded `while` forms; compare the canonical
  DSL form with direct, Builder, and JSON.
- [x] A false initial `while` condition calls no body Action and returns the
  initial State.
- [x] Check `state()`, `iteration_index()`, and the previous `body_result()`
  over several iterations. State is replaced, not merged.
- [x] Reject invalid initial State and invalid replacement State with the
  correct phase and component path.
- [x] At the limit, fail without one extra body call. Also test a body error
  before the limit.
- [x] Reject a missing bound for `while`, an invalid completion expression,
  and a Flow module in the body Action slot.

### Subflow and Choice

- [x] Compare a parent and child Flow through all four authoring forms. Check
  parent-to-child input mapping, shared context, child output mapping, and
  nested schema validation.
- [x] Use the same child twice. Each failure must retain its own authored
  path. A sibling must not receive the other child's result by accident.
- [x] Check Choice through all four forms. Test every option, overlapping
  conditions, and fallback with one data-driven case table.
- [x] Show that a result reference in an unselected Choice branch is still a
  static dependency. A selected Action failure must not run fallback.
- [x] Reject a missing fallback, a Flow target in an Action-only slot, and a
  non-Boolean direct condition before target work.

### Dispatch and continuation

- [x] Compare terminal Dispatch data through DSL, direct, Builder, and JSON.
  Its decision and expander targets are Actions.
- [x] Test a normal expander result and continuation to an Action and to a
  Flow. Check shared context and which target owns final output validation.
- [x] Confirm that the decision and ordinary Steps cannot continue. Reject a
  second Dispatch, a non-terminal Dispatch, and an output other than its
  complete result.
- [x] Reject step-wise execution and use as a Subflow before Action work. Test
  a bounded continuation chain and its limit.

## P1: authoring boundaries that combine features

### Inline Steps and host DSLs

- [x] Cover no-input, one named binding, many named bindings, a sole map
  pattern, and a context binding in complete source Flows.
- [x] Compare a compiled inline Step with its `step_action/1` target reused by
  Builder and direct construction. The new Step must supply its own params,
  needs, and metadata.
- [x] Store and restore an inline Step with a host-owned Action identifier.
  Unknown step names must not create modules or atoms.
- [x] Exercise one `Jido.Flow.Extension` macro that expands to ordinary Flow
  declarations. Check source errors and canonical data after expansion.
- [x] Reject invalid inline bindings, duplicate generated names, and a body
  with an unavailable helper at the source line. Check that recompiling an
  inline body does not turn stored graph data into a code snapshot.

### Expressions, references, and graph rules

- [x] Combine arithmetic, comparison, Boolean, and binary-concat operations
  inside nested maps and lists. Compare the four authoring forms and JSON
  bytes for one representative expression Flow.
- [x] Check missing key versus present `nil` or `false`, atom versus string
  keys, list index zero, and a missing list index in one authored program.
- [x] Reject a reference outside its component scope, a malformed path, an
  unknown operation, and unsafe expression syntax before Action work.
- [x] Check that only references and `needs` create dependencies. Source order
  and map enumeration must not. Include a diamond graph and one needs-only
  edge that does not pass data.
- [x] Reject duplicate names across different component kinds, self-cycles,
  longer cycles, missing output references, and duplicate DSL fields. Check
  the first public error and the DSL source line.
- [x] Check explicit output as the final DSL declaration. Reject absent and
  `nil` output. Do not infer output from a terminal node or source order.

### Schemas, output, and inspection

- [x] Check Flow input defaults, Action input validation, child input schema,
  Action output schema, and root Flow output schema in one composed example.
  Each failure must stop before later work.
- [x] Check map-shaped normal output and intentional `Jido.Action.Output`
  values. Reject an accidental scalar normal result at the Exec boundary.
- [x] Check that three-item Action success extras do not leak through a Flow.
- [x] Compare `validate/1`, `validate_executable/1`, `dependencies/1`,
  `explain/1`, and semantic identity across equal authoring forms. None may
  run Action work. Source locations must stay out of canonical data.
- [x] For a representative Flow without Dispatch, compare full, step-wise,
  and async final results. Check a stale step-wise revision before work starts.

### Stored JSON and Registry

- [x] Use fixed, application-owned Registry IDs and saved JSON fixture files.
  Decode real JSON bytes, run the Flow, and require stable re-encoding.
- [x] Check Registry aliases as read-only IDs and wrong-kind or unknown IDs as
  structured errors. Decoder input must not load a module or create an atom.
- [x] Test literal data that looks like `"$ref"` or `"$expr"`, registered atom
  keys, Unicode names, and version 1 versus version 2 operation documents.
- [x] Mutate a valid document with an unknown field, bad nested reference,
  duplicate component, and cycle. `Codec.diagnose/2` should report useful,
  ordered paths without running work.
- [x] Probe documented UTF-8, nesting, width, and total-node limits with
  bounded files. Keep large throughput measurements in the load suite.

## Resolved defects and expected rejections

Both defects found by this suite have enabled passing regression tests. Other
invalid fixtures above test expected rejection; they are not product failures. Known
failures in `jido/test/system` concern higher-level runtime or storage work and
must not be copied here as `jido_action` findings.

When a test exposes a defect, keep a minimal case enabled and add a row here.
Do not use a skip to make the suite green.

| ID | Status | Smallest fixture or seed | Regression check | Repro command |
| --- | --- | --- | --- | --- |
| AUTHOR-MAP-01 | Fixed; enabled regression | `MapKeyword`, `[1, :bad, 3]`, `max_concurrency: 1` | Item 3 does not start after item 2 fails. | `mix test test/authoring/components_test.exs:113 --only authoring` |
| AUTHOR-CODEC-02 | Fixed; enabled regression | Saved JSON document with `"name"` replaced by `<<255>>` | `Codec.decode/2` rejects the invalid UTF-8 name. | `mix test test/authoring/boundaries_test.exs:269 --only authoring` |

The following are required, expected rejections, not defects: Dispatch in
step-wise execution or as a Subflow; Flow modules in Action-only component
slots; unregistered stored targets; missing or `nil` output; and invalid
references, State, or graph dependencies. Record a failure only if the public
result differs from the documented contract.
