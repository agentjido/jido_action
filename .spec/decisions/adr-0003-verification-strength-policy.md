---
id: adr-0003
status: accepted
date: 2026-03-11
affects:
  - spec.system
  - jido_action.package
  - jido_action.action_contract
  - jido_action.exec.run_modes
  - jido_action.exec.reliability_controls
  - jido_action.exec.chains
  - jido_action.exec.isolation_mailbox
  - jido_action.exec.telemetry
  - jido_action.schema_adapters
  - jido_action.runtime_support
---

# Verification Strength Policy

## Context

This repo is a retrofit. Many important behaviors already have focused ExUnit
coverage, but many source files and guides do not carry stable inline requirement
markers. Trying to force file-backed linked proof for behavior-heavy surfaces
creates maintenance noise without improving confidence.

## Decision

This repo prefers targeted command verifications for runtime behavior and treats
executed proof as the default goal for behavioral subjects.

File-backed verification is reserved for workspace artifacts and places where the
target can carry stable `covers:` markers or literal requirement ids without
polluting production files.

## Consequences

- behavioral subjects should usually point at the smallest existing test slice
- workspace files can stay file-backed because they are already annotation-friendly
- maintainers should only add file-backed runtime verification when a stable marker
  strategy is obvious
- `mix spec.verify --debug` and `mix spec.check` remain the final gate for changes
