# `.spec/decisions`

This folder stores durable architectural decision records for the Spec Led Development
workspace.

<!-- spec.workspace.decisions_present -->

## Use ADRs For

- cross-cutting decisions that affect multiple current-truth subjects
- durable repo rules that should outlive a single branch or PR
- policy choices that an agent or maintainer should apply consistently

## Do Not Use ADRs For

- feature proposals or in-flight implementation notes
- branch-local TODO lists
- changes that Git history already explains well enough

Git branches, commits, and pull requests remain the time dimension for this repo.
The `.spec` workspace stays declarative and describes merged current truth only.

## Current ADRs

- `adr-0001-declarative-current-truth.md`
- `adr-0002-jido-exec-subject-decomposition.md`
- `adr-0003-verification-strength-policy.md`
