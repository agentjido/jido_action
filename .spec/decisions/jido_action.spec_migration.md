---
id: jido_action.spec_migration
status: accepted
date: 2026-03-28
affects:
  - repo.governance
---

# Adopt subsystem-based Spec Led subjects

## Context

This repository exposes multiple durable surfaces: action definition, schema handling,
execution policy, workflow planning, built-in tools, and scaffolding/docs. The first
bootstrap slice added package and scaffolding subjects, but the full migration spans the
entire library, guide set, and test suite. Without a stable subject map, future work would
either drift back into a single catch-all package subject or create overlapping subjects
that make branch guidance noisy and difficult to maintain.

## Decision

The repository will organize its authored Spec Led subjects by subsystem boundary.
Each major package surface owns its code, guides, and tests in one durable subject:

- `jido_action.package` for the package-level contract and shared repo harness files
- `jido_action.action` for `use Jido.Action` metadata, lifecycle, and tool conversion
- `jido_action.exec` for execution/runtime policy
- `jido_action.sanitizer` for shared transport and telemetry sanitization of arbitrary runtime terms
- `jido_action.schema` for schema adapters and JSON Schema handling
- `jido_action.workflow` for instructions, plans, and workflow/action-plan helpers
- `jido_action.tools` for built-in tool actions
- `jido_action.error_handling` for normalized error types
- `jido_action.scaffolding` for install/generator tasks, examples, and maintainer support docs

Future spec work should extend one of these subjects before introducing a new one. A new
subject is appropriate only when the behavior defines a distinct, durable boundary that does
not fit an existing subsystem.

Shared infrastructure that becomes a public package surface across multiple subsystems may
also warrant its own subject once it carries distinct runtime guarantees. The sanitizer
boundary falls into that category because it defines the reusable transport and telemetry
contract consumed by error handling, tool execution, and execution observability.

Package-level current truth may also co-own outward-facing contracts that span subsystem
boundaries, while the subsystem subject continues to own the detailed mechanics. When a
change materially affects both a subsystem surface and the package-level contract, update
both authored subjects together instead of forcing the behavior into only one subject.

## Consequences

- Branch guidance can treat most changes as updates to a known subsystem instead of recurring
  uncovered frontier work.
- Guides and tests stay co-owned with the subsystem they document or verify, which keeps
  `mix spec.next` and `mix spec.status` actionable.
- Cross-cutting changes that reshape subject boundaries should update this ADR alongside the
  affected subject specs.
