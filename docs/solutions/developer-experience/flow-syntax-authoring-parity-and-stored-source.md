---
title: Add Flow Syntax Through Authoring Parity and Parser Profiles
date: 2026-06-25
category: developer-experience
module: Jido.Flow
problem_type: developer_experience
component: tooling
severity: medium
applies_when:
  - "Adding small Flow DSL syntax on top of the canonical IR"
  - "Keeping builder, macro DSL, and text parser surfaces semantically aligned"
  - "Making stored or user-edited Flow source safer without changing the IR"
related_components:
  - "Jido.Flow.Syntax"
  - "Jido.Flow.DSL"
  - "Jido.Flow.Parser"
  - "Jido.Flow.Syntax.Lowerer"
tags:
  - flow
  - dsl
  - parser
  - runic
  - authoring-parity
  - provenance
---

# Add Flow Syntax Through Authoring Parity and Parser Profiles

## Context

Flow syntax work needs to stay small enough to implement on top of Runic without
misdirecting users about what the language can actually guarantee. The latest
slice added two low-risk pieces: provenance-only step annotations and an
explicit stored parser profile.

The useful learning is not just the two syntax additions. The durable pattern is
that each new syntax feature should be grounded in the canonical Flow IR first,
then proven across every authoring surface before the language moves toward
larger concepts like map, reduce, accumulate, loops, or ReAct-style agent flows.

## Guidance

Treat new Flow syntax as an authoring convenience over a stable semantic core.
For this slice, `label`, `tags`, and `note` are stored only in node provenance:

```elixir
added =
  step(:add_one, Add,
    with: %{value: input(:value), amount: value(1)},
    label: "Add one",
    tags: [:math, "example"],
    note: "Visible only in provenance"
  )
```

The semantic map stays unchanged by default. Tooling that needs labels or notes
must ask for provenance explicitly:

```elixir
Flow.to_map(flow)
Flow.to_map(flow, provenance: true)
```

Keep the parser profile explicit. Trusted developer source remains the default,
while stored source opts into a safer parser posture:

```elixir
Flow.parse(source,
  name: "annotated_flow",
  profile: :stored,
  actions: %{"add" => JidoTest.TestActions.Add}
)
```

Stored source should resolve actions through an explicit registry instead of
accepting arbitrary module aliases. That keeps the stored profile useful without
changing the current atom-and-module canonical IR.

When adding syntax, add parity fixtures before broadening the language surface.
The same feature should round-trip through direct syntax, builder APIs, macro
DSL, trusted source parsing, and, when relevant, stored source parsing. Tests
should compare default semantic maps for equality and inspect provenance only in
provenance-enabled output.

## Why This Matters

Syntax additions are easy to make misleading. A parser can accept pleasant text
long before the IR, compiler, and runtime have a durable meaning for it. That is
especially risky for future control-flow concepts: Runic may support map,
reduce, accumulators, joins, context, and runners, but Flow still needs its own
canonical semantics before exposing those ideas as language syntax.

The annotation and stored-profile work gives Flow two important affordances
without overcommitting:

- Human-facing tooling can display labels, tags, notes, line numbers, and column
  positions without changing execution or dependency semantics.
- Stored source can be parsed without creating arbitrary atoms or resolving
  arbitrary module aliases from user-edited text.

That preserves the project boundary captured elsewhere: `Jido.Flow` models IR
and action composability, while `Jido.Exec` remains responsible for invocation
normalization.

## When to Apply

- When adding a new Flow keyword, expression helper, parser option, or authoring
  affordance.
- When a feature should improve readability, diagnostics, visualization, or
  source storage without changing runtime behavior.
- When stored or user-edited Flow source needs a safer entry point.
- Before introducing dynamic concepts such as `each`, map, reduce, accumulate,
  loop, or ReAct agent control flow.

## Examples

Use provenance-only assertions to prevent semantic drift:

```elixir
assert Flow.to_map(annotated_flow) == FlowFixtures.annotated_canonical_map()

assert [%{provenance: provenance}] =
         Flow.to_map(annotated_flow, provenance: true).nodes

assert Map.take(provenance, [:label, :tags, :note]) == %{
         label: "Add one",
         tags: ["math", "example"],
         note: "Visible only in provenance"
       }
```

Use stored-source tests to prove the parser fails closed:

```elixir
assert {:ok, flow} =
         Flow.parse(FlowFixtures.stored_annotated_source(),
           name: "annotated_flow",
           profile: :stored,
           actions: %{"add" => JidoTest.TestActions.Add}
         )

assert Flow.to_map(flow) == FlowFixtures.annotated_canonical_map()
assert {:ok, %{value: 4}} = Jido.Exec.run(flow, %{value: 3}, %{})
```

Also test rejection paths before relying on the feature:

- Unsupported parser profiles fail before lowering.
- Stored source rejects source atoms that do not already exist.
- Stored source rejects unregistered action identifiers.
- Stored source rejects direct module aliases in action position.
- Annotation values are literal-only and normalize to strings for tags.

The completed slice was verified with the full suite and coverage run:

- `mix test`: 312 tests passing.
- `mix test --cover`: 312 tests passing, 97.04% total coverage.

## Related

- `docs/plans/2026-06-25-007-feat-remaining-flow-syntax-plan.md`
- `docs/solutions/architecture-patterns/flow-ir-exec-invocation-boundary.md`
- `lib/jido_flow/syntax.ex`
- `lib/jido_flow/dsl.ex`
- `lib/jido_flow/parser.ex`
- `lib/jido_flow/syntax/lowerer.ex`
- `test/integration/flow_parity_test.exs`
- `test/jido_flow/parser_test.exs`
