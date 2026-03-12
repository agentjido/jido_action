---
id: adr-0002
status: accepted
date: 2026-03-11
affects:
  - jido_action.package
  - jido_action.exec.run_modes
  - jido_action.exec.reliability_controls
  - jido_action.exec.chains
  - jido_action.exec.isolation_mailbox
  - jido_action.exec.telemetry
---

# Jido.Exec Subject Decomposition

## Context

`Jido.Exec` is a broad runtime surface. A single coarse execution spec was enough
for initial retrofit adoption, but it did not help maintainers reason about the
different parts of the execution system. The runtime includes distinct concerns:
entrypoints, retry and timeout policy, chain execution, supervision isolation,
mailbox hygiene, and telemetry sanitization.

## Decision

The execution layer is split into five current-truth subjects:

- run modes
- retries, timeouts, compensation, and runtime defaults
- chain execution and interruption
- instance isolation and mailbox hygiene
- telemetry modes and payload sanitization

Each subject uses focused command verifications tied to the existing exec test
files instead of one broad umbrella command.

## Consequences

- execution specs are easier to refine without rewriting a single giant subject
- coverage gaps in one execution area are easier to see
- maintainers can change one exec subsystem without weakening the whole package spec
- package-level execution coverage now depends on several smaller subject files
