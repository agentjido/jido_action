# AGENTS.md

## Branch Context

This branch is an exploratory foundation for Jido Action v4: a heavily curated,
trimmed down package that starts from `Jido.Action` and `Jido.Instruction`.

The preserved `JIDO_V4_BRIEF.md` is the design artifact for future composition
work. The current codebase intentionally avoids carrying forward the prior
composition/runtime implementation.

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

- `telemetry`
- `zoi`
- `runic`
- `splode`

Do not add direct production dependencies outside this set without an explicit
request. Dev and test dependencies should remain pragmatic and support the TDD
workflow.

## Design Direction

- Keep the rebuilt surface area slim and explicit.
- Treat `Jido.Instruction` as a small action call frame, not a workflow or
  execution policy container.
- Reintroduce composition/runtime behavior only through the v4 design, not
  through compatibility shims from the previous spike.
