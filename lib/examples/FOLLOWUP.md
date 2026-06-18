# Jido Action v3 Examples Follow-Up

This note captures what the `lib/examples` scripts exposed while building and
running the 51-example ad-hoc suite. The examples should stay ad-hoc for now:
they are exploratory scripts, not a formal test harness, docs site, or release
artifact. Their value is in quickly pressure-testing behavior and making design
friction visible.

## How To Use This Note

Use this as a prompt bank for architecture follow-up. Each section names the
friction, explains the current behavior, and offers refinement questions.

The examples are intentionally runnable with:

```sh
mix run lib/examples/NN_name.exs
mix run lib/examples/run_all.exs
```

`run_all.exs` shells out to `mix run` for each numbered example. That is slower
than evaluating all scripts in one VM, but it matches the intended usage and
avoids shared-process artifacts from examples that intentionally test exits,
logging, telemetry handlers, and process boundaries.

## Keep Examples Ad-Hoc

For this spike, the examples should remain lightweight scripts.

Reasons:

- They can demonstrate rough edges without committing those rough edges as
  supported contracts.
- They can be noisy and verbose in ways tests should not be.
- They can include exploratory scenarios such as process exits, raw Runic
  projections, JSON projection failures, and telemetry inspection.
- They can change quickly as `Jido.Flow` and `Jido.Exec` settle.

What not to do yet:

- Do not turn every example into ExUnit coverage.
- Do not wire examples into `mix quality`.
- Do not treat example output as a stable public snapshot.
- Do not polish these into release documentation until the API is less fluid.

Useful lightweight discipline:

- Keep each script self-checking with pattern matches.
- Keep each script focused on one concept.
- Let `run_all.exs` remain a smoke runner, not a CI gate.

## Current State Snapshot

Settled enough for now:

- `Jido.Exec` accepts flat `run_context` and maps it to Runic global context.
- Jido action success is strict: normal success is map-shaped.
- Abnormal successful action outputs use `Jido.Action.Output`.
- Bare scalar, list, stream, or struct success values remain invalid return
  shapes unless wrapped in `Jido.Action.Output`.
- `Jido.Flow.to_map/1` is still Elixir-term IR, not a JSON/YAML transport
  format.
- Flow IR structural keys and component identifiers are atom-only.
- String-keyed Flow structural maps are rejected instead of normalized.
- Runtime code does not call `String.to_atom/1` for Flow names. Implicit action
  name derivation only uses existing atoms; direct `Exec.run/3` and
  `Exec.step/3` can pass `name: :explicit_name`.
- `Exec.resume(result)` continues queued work without requiring `nil` input.
- `Exec.results(result)` hides generated Runic internal nodes; `raw: true`
  remains the low-level escape hatch.

Most useful next pressure points:

- Add a projection/extraction primitive for feeding action output fields into
  Runic map/reduce pipelines.
- Decide whether future scripting gets a separate adapter, compiler, or builder
  layer over the atom-keyed Elixir-term IR.
- Decide whether provenance should get a step-aware Jido projection.

## 1. Run Context Shape

### What The Examples Exposed

`09_branch_local_context.exs` initially assumed runtime context was flat:

```elixir
run_context: %{tenant: "acme"}
```

That originally did not reach the step context. Runic resolves runtime context
by component name and supports shared context through `:_global`:

```elixir
run_context: %{_global: %{tenant: "acme"}}
```

`Jido.Exec` now wraps flat context maps into `:_global`, so the flat shape works
for ordinary action execution while the explicit Runic shape remains available.

### Current Interpretation

Runic's context shape is still the engine-native shape, but Jido now has an
action-friendly convenience at the `Exec` boundary.

### Current Behavior

Flat context:

```elixir
Exec.run(flow, input, run_context: %{tenant: "acme"})
```

is treated as global action context.

Explicit Runic-shaped context remains available:

```elixir
Exec.run(flow, input,
  run_context: %{
    _global: %{tenant: "acme"},
    enrich: %{trace_id: "step-local"}
  }
)
```

### Remaining Risk

The current implementation detects Runic-shaped context heuristically by
checking for `:_global`, `"_global"`, or keys matching workflow component
names. That creates one edge case: a flat context key that happens to match a
component name is interpreted as component-local context.

### Deferred Alternative

If the heuristic becomes uncomfortable, add a separate Jido-only runtime option
later:

```elixir
Exec.run(flow, input, context: %{tenant: "acme"})
```

and reserve `:run_context` for exact Runic context shape.

### Feedback Prompts

- Keep the current `run_context` heuristic, or split Jido `:context` from Runic
  `:run_context`?
- Should component-keyed context require `:_global` to avoid ambiguity?
- Are string component names in `run_context` important for external
  projections?

## 2. Action Outputs Are Map-Boundary Leaves With Explicit Envelopes

### What The Examples Exposed

`14_actions_plus_primitives.exs` originally tried to have a Jido action emit a
bare list into a Runic map/reduce pipeline. That failed because Jido action
output validation expects map-shaped action results.

The example was changed to demonstrate sibling execution over the same list
input:

- a Jido action counts the input list
- Runic primitives map/reduce the input list

### Current Interpretation

This is coherent if Jido actions are leaf call frames with map params and map
outputs. It keeps action contracts predictable.

The new explicit escape hatch is `Jido.Action.Output`. It solves abnormal
successful values without weakening the normal action contract.

`34_streaming_result.exs` and `51_action_output_envelopes.exs` now demonstrate
the explicit abnormal-success path:

```elixir
{:ok, Jido.Action.Output.stream(stream, meta: %{source: :range})}
{:ok, Jido.Action.Output.raw(payload, meta: %{source: :external})}
{:ok, Jido.Action.Output.batch(values, meta: %{count: count})}
{:ok, Jido.Action.Output.opaque(handle), %{route: :inspect}}
```

These envelopes are terminal action results. They make abnormal success visible
without weakening normal map-shaped action outputs.

### Current Behavior

Normal success:

```elixir
{:ok, %{value: 10}}
{:ok, %{value: 10}, %{route: :next}}
```

Abnormal success:

```elixir
{:ok, Jido.Action.Output.raw(term)}
{:ok, Jido.Action.Output.stream(enumerable)}
{:ok, Jido.Action.Output.batch(list)}
{:ok, Jido.Action.Output.opaque(term)}
```

Invalid success:

```elixir
{:ok, [1, 2, 3]}
{:ok, Stream.map(1..3, & &1)}
{:ok, some_struct}
```

Those are intentionally rejected as unexpected action return shapes.

### Remaining Friction

An output envelope is not a data-flow bridge. It is a terminal result envelope.
This means a flow still needs an explicit projection/extraction primitive if an
action produces `%{items: [...]}` or `Output.batch(items)` and a later Runic
primitive should map or reduce those items.

### Rejected Path

Allowing scalar/list action outputs would fit data-flow pipelines superficially,
but it weakens action contracts and creates silent ambiguity between normal
Jido actions and raw Runic data flow. Keep this cut.

### Next Design Target

Add explicit projection/extraction primitives.

Examples:

```elixir
Flow.project(:items, from: :load_items, path: [:items])
Flow.map(:score_each, {Scoring, :score}, after: :items)
```

or:

```elixir
Flow.step(:load_items, LoadItems)
Flow.map(:score_each, {Scoring, :score}, after: {:load_items, :items})
```

- Pros: Keeps actions map-shaped while enabling data-flow composition.
- Cons: Adds new Flow API and IR shape.

### Feedback Prompts

- Should abnormal output envelopes remain terminal results until a projection
  primitive exists?
- Do we need a `Flow.project/3` or `Flow.extract/3` primitive?
- Should primitive inputs support paths into prior action outputs?
- Should `Output.batch(values)` be projectable by kind, or should projection
  only target map fields?
- Should this wait until JSON/YAML/script projections are designed?

## 3. Flow IR Is Elixir-Term IR

### What The Examples Exposed

`36_json_safe_ir.exs`, `37_non_json_safe_ir.exs`, and
`50_end_to_end_spike.exs` show that `Flow.to_map/1` is a useful Elixir-term IR,
but not a clean JSON/YAML IR.

Examples:

- modules encode through Jason as strings
- policies are tuples
- fallback functions cannot be JSON-encoded
- MFA/capture references need explicit projection
- runtime-only workflows are rejected by `to_map/1`

### Current Interpretation

This is the intended direction for now. `Flow.to_map/1` is the internal
normalized Elixir-term shape, not a transport format. JSON/YAML/script
projection should wait.

The risk is naming. `to_map/1` can sound like "plain serializable map" when it
really means "normalized Elixir-term representation."

### Current Decision

Keep `to_map/1` as Elixir-term IR:

- modules remain modules
- callables remain MFA/capture-normalized Elixir terms
- policies remain Elixir terms
- runtime-only workflows remain rejected by `to_map/1`

Do not make `to_map/1` JSON-safe in this spike.

### Remaining Risk

If `to_map/1` reads too much like "external map", consider renaming or adding a
more explicit alias later:

```elixir
Flow.to_ir(flow)
Flow.to_term(flow)
```

### Feedback Prompts

- Is `to_map/1` clear enough for Elixir-term IR, or should we add `to_ir/1`?
- Should future external projections be separate modules/functions rather than
  options on `to_map/1`?
- Should examples 36-38 keep warning about external encoding limits, or should
  JSON-oriented examples move out until there is a real adapter?

## 4. String Keys In Flow Shape vs Action Params

### What The Examples Exposed

`38_ir_round_trip_shape.exs` originally showed that `Flow.new/1` accepted string
keys for Flow structure:

```elixir
%{"type" => "step", "name" => "add"}
```

while action params remained untouched:

```elixir
%{"amount" => 4}
```

That mixed boundary was too loose. It made the Flow IR look compatible with
external string-keyed maps while leaving action payload decoding unresolved.

### Current Interpretation

The current Flow IR is an Elixir-term IR. Flow structural keys and component
identifiers are atoms. Action params and context remain action-owned data and
are passed through unchanged.

### Why Not Normalize All Atom Keys To Strings?

Normalizing all atom keys to strings would optimize for an external transport
format we are explicitly not targeting right now. For Elixir-term IR it creates
more problems than it solves:

- It makes pattern matching and internal construction less idiomatic in Elixir.
- It pushes every action schema toward string-keyed params even though Jido
  actions currently validate atom-keyed maps.
- It mutates user-owned action params at the Flow layer, which is surprising.
- It does not improve atom safety. The risky direction is converting unknown
  strings to atoms; keeping known structural atoms is safe.
- It blurs the boundary between Flow structure and action payload data.

The better split:

- Flow structural keys are atoms.
- Flow component identifiers are atoms.
- Action params and context should pass through unchanged.
- Any future external projection should have its own string-keyed wire shape and
  explicit decode step.
- No runtime path should call `String.to_atom/1` for Flow names. Implicit action
  name derivation may only use `String.to_existing_atom/1`; otherwise callers
  must pass an explicit atom `:name`.

### Remaining Friction

If script/YAML inputs become a target later, both structural keys and
string-keyed params will need a separate decoding story. That should happen
through action schemas or an explicit projection adapter, not through
`Jido.Flow` blindly rewriting payload keys.

The scripting layer is expected to have more exposure because strings become
code and may create atoms during compilation. That risk should stay at the
scripting boundary. The Flow IR should remain the hardened foundation beneath
it, accepting already-formed atoms rather than interning untrusted strings.

### Preferred Direction

Keep the boundary strict:

```elixir
Flow.new(%{flow: [%{type: :step, name: :add}]})
```

is Flow IR, while:

```elixir
params: %{"amount" => 4}
```

remains action data and is not automatically rewritten to `%{amount: 4}`.

String-keyed structural maps should fail at the Flow boundary:

```elixir
Flow.new(%{"flow" => [%{"type" => "step", "name" => "add"}]})
```

### Feedback Prompts

- Should Flow ever transform action params? Current answer: no.
- Should action schemas eventually expose safe param decoding from string-keyed
  external maps? Current answer: maybe, but not in `Jido.Flow`.
- Should `Flow.to_map/1` guarantee atom-keyed structural fields as part of the
  Elixir-term IR contract? Current answer: yes.
- Should examples include a future scripting adapter concept without
  implementing JSON/YAML? Current answer: only if it helps pressure-test the
  boundary without becoming docs.

## 5. Resume Without Input

### What The Examples Exposed

`16_step_once_and_resume.exs`, `17_max_cycles_partial_work.exs`, and
`46_partial_execution_ui_model.exs` originally used:

```elixir
Exec.resume(result, nil)
```

That worked, but the call read awkwardly. The intent was "continue already
queued work without adding a new fact."

### Current Interpretation

This is now handled directly:

```elixir
Exec.resume(result)
```

continues queued work without adding input. Existing input-bearing resume still
works:

```elixir
Exec.resume(result, input)
Exec.resume(result, input, opts)
```

### Current Decision

Support `Exec.resume(result)` and keep the verb count small. Do not add
`Exec.continue/1` or `Exec.drain/1` yet.

### Feedback Prompts

- Is `resume(result)` clear enough now that input is optional?
- Should a future debugger API add `Exec.step(result)`, or should stepping stay
  flow/action/instruction-only?
- Should `resume(result, opts)` exist, or is that too ambiguous because input
  can itself be a keyword list?

## 6. Normal Results Hide Runic Internal Nodes

### What The Examples Exposed

Examples using `Flow.map/4` show raw results such as:

```elixir
%{
  :double_each => [2, 4, 6],
  "step_2204933384" => [2, 4, 6]
}
```

The internal step name comes from Runic's map pipeline.

### Current Interpretation

Normal result reads should be Jido-facing. Generated Runic internals are useful
debug data, but they should not appear unless explicitly requested.

### Current Behavior

`Exec.results(result)` and `Exec.results(result, raw: false)` hide generated
Runic internal nodes such as `"step_2204933384"`.

`Exec.results(result, refresh: true)` uses the same Jido-facing filtering.

`Exec.results(result, raw: true)` remains the low-level escape hatch and returns
raw Runic productions.

### Remaining Friction

The current filter is intentionally narrow: it hides generated Runic workflow
steps behind primitives. It does not attempt to redesign result projection for
all mixed primitive/action flows. A richer `Exec.outputs/1` or projection mode
may still be useful later.

### Feedback Prompts

- Is the narrow generated-step filter enough, or do we need explicit node
  visibility metadata?
- Do we need `Exec.outputs/1` as a Jido-facing result projection?
- What should map/reduce primitive outputs look like in Jido result space?

## 7. Charlist Rendering Is A Display Problem

### What The Examples Exposed

Reduce results like `[10]` printed as `~c"\n"` until the shared example printer
used:

```elixir
charlists: :as_lists
```

### Current Interpretation

This is not a Jido bug. It is an Elixir inspection default.

### Design Choices

No library change is needed. Example output should keep using explicit inspect
options.

### Feedback Prompts

- Should examples consistently use a `Support.print/2` helper? Current answer:
  yes.
- Should public docs mention `charlists: :as_lists` when inspecting raw integer
  lists? Probably not unless this comes up repeatedly.

## 8. Process Boundary And Runner Shape

### What The Examples Exposed

Running all examples through `Code.eval_file/1` in one VM was not equivalent to
running:

```sh
mix run lib/examples/NN_name.exs
```

The process-exit example made the shared VM runner brittle, even though each
script worked when invoked normally.

### Current Interpretation

The examples should be run as isolated scripts. That is the user-facing shape
and it keeps intentionally hostile examples from contaminating the rest of the
suite.

### Design Choices

Option A: Keep `run_all.exs` shelling out per script.

- Pros: Faithful and robust.
- Cons: Slower.

Option B: Remove `run_all.exs`.

- Pros: Avoids making examples look like tests.
- Cons: Loses quick smoke check.

Option C: Split hostile examples out of `run_all.exs`.

- Pros: Faster shared-VM runner for safe examples.
- Cons: More bookkeeping and less faithful to `mix run`.

### Feedback Prompts

- Is the slower `run_all.exs` acceptable?
- Should process-hostile examples be opt-in?
- Should `run_all.exs` stay unadvertised and ad-hoc?

Current preference: keep examples ad-hoc and keep `run_all.exs` as a convenient
manual smoke runner, not a CI target.

## 9. Directives And Provenance Can Look Redundant

### What The Examples Exposed

Directive and audit examples can show provenance like:

```elixir
[%{value: 6}, %{value: 6}, %{value: 10}]
```

This is technically correct: different facts can carry equal values. It can
look redundant when the directive step returns the same value it received.

### Current Interpretation

No implementation change is required. This is a display and explanation issue.

### Design Choices

Option A: Keep provenance fact-oriented.

- Pros: Correct data-flow semantics.
- Cons: Output can look visually repetitive.

Option B: Add richer provenance projection.

Example:

```elixir
[
  %{step: :input, value: %{value: 6}},
  %{step: :directive, value: %{value: 6}},
  %{step: :add, value: %{value: 10}}
]
```

- Pros: Easier to inspect.
- Cons: More projection logic.

### Feedback Prompts

- Should `Exec.provenance/2` stay fact-level only?
- Should there be a Jido-facing provenance projection with step names?
- Do directives need a richer audit story?

## 10. Telemetry Shape Is Working

### What The Examples Exposed

`49_flow_observability_telemetry.exs` was straightforward. The action span
boundary is usable and low-cardinality.

### Current Interpretation

This validates the earlier decision to preserve action telemetry shape while
moving runtime execution to Runic.

### Design Choices

No immediate change required.

Potential later additions:

- flow-level telemetry
- step scheduling telemetry
- policy retry/timeout metadata
- directive metadata counts

### Feedback Prompts

- Is action telemetry enough for v3?
- Do we need flow-level events, or should Runic events cover that?
- Should telemetry include flow/step names, or is action module enough?

## Suggested Next Refinement Order

1. Design `Flow.project/3` or `Flow.extract/3` so action outputs can feed Runic
   primitives without loosening the action return contract.
2. Decide whether `Flow.to_map/1` should get a clearer Elixir-term alias such
   as `Flow.to_ir/1`.
3. Design the future scripting boundary over Flow IR without making Flow itself
   intern strings or accept string-keyed structure.
4. Decide whether action schemas should expose safe param decoding from
   string-keyed external maps.
5. Pressure test whether flat `run_context` should stay heuristic or split into
   separate Jido `:context` and Runic `:run_context` options.
6. Decide whether provenance should get a Jido-facing step/value projection.
7. Decide whether normal results need a richer `Exec.outputs/1` projection
   beyond the current generated-Runic-step filter.

## Prompt Starters

Use these as follow-up prompts:

- "Design `Flow.project/3` or `Flow.extract/3` for action output paths and
  `Jido.Action.Output.batch/1`."
- "Review examples 14, 34, 43, and 51. What is the right bridge between
  map-shaped Actions, output envelopes, and enumerable Runic primitives?"
- "Design the future scripting layer over the atom-keyed Elixir-term IR. Where
  are atoms allowed to be created, and how is that exposure bounded?"
- "Pressure test whether `Flow.to_map/1` should be renamed or aliased to
  `Flow.to_ir/1`."
- "Review `Exec.results/1` after generated Runic internals are hidden. Do we
  still need `Exec.outputs/1`?"
- "Should flat `run_context` stay heuristic, or should Jido add a separate
  `:context` option while reserving `:run_context` for exact Runic shape?"
- "Design a step-aware provenance projection for audit/debug output."
