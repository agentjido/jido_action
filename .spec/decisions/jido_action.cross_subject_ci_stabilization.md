---
id: jido_action.cross_subject_ci_stabilization
status: accepted
date: 2026-04-03
affects:
  - jido_action.package
  - jido_action.exec
---

# Keep package graph fixes and exec verification stabilization together when CI exposes both

## Context

A package-manifest change can legitimately start in the `jido_action.package` subject and still
surface a latent verification problem owned by `jido_action.exec`. In this branch, the direct
`multigraph` dependency update changed `mix.exs`, while the Specs workflow also exposed that the
timeout leak assertion in the exec suite was sampling the shared global task supervisor and could
observe unrelated concurrent tasks.

The repository's branch guard is intentionally strict about cross-subject changes. When a branch
touches both package-level current truth and execution verification stability, the authored specs
need an explicit durable record of why those subjects moved together instead of pretending they are
unrelated.

## Decision

When a package-level dependency or publishing fix uncovers nondeterministic execution verification,
the branch may update both `jido_action.package` and `jido_action.exec` in the same pull request as
long as the execution-side change remains within the owning subject boundary.

For timeout cleanup assertions specifically, verification should prefer an isolated instance-scoped
task supervisor over the shared global supervisor so the check measures cleanup behavior rather than
ambient concurrent work from other exec tests.

## Consequences

- Branch guidance can treat this class of work as intentional cross-subject maintenance rather than
  an uncovered spec miss.
- The package subject continues to own publishable dependency graph truth.
- The exec subject continues to own timeout cleanup verification mechanics and supervisor-isolation
  expectations.
