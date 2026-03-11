---
id: adr-0001
status: accepted
date: 2026-03-11
affects:
  - spec.system
  - jido_action.package
---

# Declarative Current Truth Only

## Context

This repo is using Spec Led Development as a current-state contract for a mature
library. The package already has Git branches, commits, and pull requests as the
change history. Adding another in-repo layer for in-flight change tracking would
create duplicate time-based state and make the `.spec` workspace harder to trust.

## Decision

The `.spec` workspace records merged current truth only.

Git history carries changes over time:

- branches hold in-flight work
- commits explain step-by-step evolution
- pull requests capture review and merge context

This repo uses ADRs only for durable cross-cutting decisions that affect multiple
subjects or the overall spec workflow.

## Consequences

- subject specs should describe the current package, not proposed futures
- maintainers should update current-truth specs in the same branch as code changes
- agents should look to Git history for the evolution of a change
- ADRs stay rare and should only capture stable decisions worth reusing later
