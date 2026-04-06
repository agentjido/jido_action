---
id: jido_action.execution_logging_hygiene
status: accepted
date: 2026-04-03
affects:
  - jido_action.exec
  - jido_action.package
  - jido_action.tools
---

# Keep execution logging local and legacy-safe

## Context

The logging remediation branch kept behavior worth preserving from the earlier PR
discussion, but narrowed ownership based on follow-up review:

- shared `Jido.Action.Log` facade ownership should not survive the rewrite
- inspected runtime values still need bounded, sanitized logging where execution
  and telemetry paths emit them
- routine execution traces should stay quiet unless callers explicitly opt into a
  debug-oriented `:log_level`
- richer raw atom failure metadata is useful downstream, but changing the default
  failure shape would be a breaking change for existing callers
- supervised timeout cleanup in the Lua tool has to leave mailboxes and task
  monitors clean so runtime and test isolation stay aligned

## Decision

`jido_action` treats execution logging hygiene as a cross-cutting rule with local
ownership at each boundary:

- execution and telemetry code may use direct `Logger` APIs or small local helper
  functions, but not a package-wide logging facade module
- sanitization and bounded inspection stay in the owning execution boundary that
  emits the log event
- routine start and success traces require explicit caller opt-in through
  `:log_level`, while invalid configuration and runtime failures remain visible at
  warning or error levels
- raw atom error normalization keeps the historical collapsed-details shape by
  default; richer retry metadata is available only behind explicit opt-in
- supervised Lua timeout handling must clean up task, monitor, and mailbox residue
  before returning control to the caller

## Consequences

- Current truth for execution, package-level execution defaults, and built-in tools
  should move together when this policy changes.
- Local log message wording can evolve without revisiting this ADR.
- Future changes that centralize logging ownership again, or that alter the default
  error shape, should update this ADR alongside the affected subject specs.
