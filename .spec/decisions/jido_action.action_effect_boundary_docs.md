---
id: jido_action.action_effect_boundary_docs
status: accepted
date: 2026-04-06
affects:
  - jido_action.package
  - jido_action.action
  - jido_action.scaffolding
---

# Document the action effects boundary consistently across package, action, and FAQ surfaces

## Context

The repository already ships effectful action examples and built-in HTTP and file-system tooling,
but the outward-facing docs previously left the action purity boundary implicit. That created a
recurring question across the Jido ecosystem: whether `Jido.Action.run/2` is expected to stay pure,
or whether side effects belong there while `jido` keeps purity at a higher runtime boundary.

This ambiguity spans multiple durable subjects. The README owns package onboarding, the action
subject owns the `Jido.Action` moduledoc plus the Actions guide, and the scaffolding subject owns
the maintainer-facing FAQ.

## Decision

The package, action, and scaffolding subjects shall document the same boundary:

- `Jido.Action` modules are reusable execution units.
- An action's `run/2` may be pure or effectful.
- Inline I/O is acceptable when the step needs the result immediately to continue.
- When the effect should instead belong to a runtime or integration boundary, the docs should say
  to hand it off there rather than performing it inline.
- When actions run inside `jido`, the purity guarantee belongs to the agent or strategy `cmd/2`
  boundary, not necessarily to each action the runtime invokes behind it.

## Consequences

- README onboarding now carries the package-level explanation instead of relying on inference.
- The action subject now owns explicit purity guidance in both the moduledoc and the Actions guide.
- The FAQ now owns a direct maintainer-facing answer for side effects and HTTP calls.
