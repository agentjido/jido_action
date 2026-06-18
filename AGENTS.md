# AGENTS.md

## Branch Context

This branch is an exploratory spike for Jido Action v3: a heavily curated,
trimmed down, focused rebuild of `Jido.Action`, `Jido.Instruction`, and
`Jido.Exec` on top of Runic.

The branch also introduces `Jido.Flow`, a Runic-backed data structure for
capturing action composition.

## Working Mode

- Use TDD exclusively for analysis and iteration.
- Establish the current test and coverage baseline before changing behavior.
- Keep meaningful test coverage for touched modules.
- Prefer focused tests around the module being changed, then run the broader
  suite when the change can affect shared behavior.
- This is a spike. Ignore release hygiene unless explicitly requested.
- Do not spend time on docs, changelog, package metadata, Dialyzer, Hex release
  tasks, or similar release preparation unless explicitly requested.

## Runtime Targets

- Target OTP 29.
- Target Elixir 1.20.

## Dependency Policy

Keep production dependencies focused. The only intended direct production
dependencies are:

- `jason`
- `telemetry`
- `zoi`
- `runic`
- `splode`

Do not add direct production dependencies outside this set without an explicit
request. Dev and test dependencies should remain pragmatic and support the TDD
workflow.

## Design Direction

- Keep the rebuilt surface area slim and explicit.
- Favor Runic-backed data flow primitives over legacy execution abstractions.
- Treat `Jido.Instruction` as a small action call frame, not a workflow or
  execution policy container.
- Treat `Jido.Flow` as the composition structure for action graphs and scripts.
- Avoid preserving compatibility shims unless they are intentionally part of the
  v3 target behavior.
