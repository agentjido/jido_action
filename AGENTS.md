# AGENTS.md

## Branch Context

This branch contains the Jido Action v3 spike and the exploratory Jido Action v4
foundation. It starts from a small `Jido.Action` and `Jido.Instruction` core. It
also contains the new `Jido.Flow` and `Jido.Exec` composition foundation.

Use these records for future design work:

- `JIDO_V4_BRIEF.md` defines the package boundary and composition direction.
- `RUNIC_CAPABILITY_BASELINE.md` records the Runic baseline for Flow Script.
- `GOVERNED_AGENTS_BRIEF.md` records the wider product position.
- `LONG_RUNNING_AGENTS_POSITION.md` records the runtime and governance case.

The product records are design inputs. They are not package requirements. Do
not restore the composition or runtime implementation from the earlier spike.

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
- `spark`

Do not add direct production dependencies outside this set without an explicit
request. Dev and test dependencies should remain pragmatic and support the TDD
workflow.

## Design Direction

- Keep the rebuilt surface area slim and explicit.
- Treat `Jido.Instruction` as a small action call frame, not a workflow or
  execution policy container.
- Reintroduce composition/runtime behavior only through the v4 design, not
  through compatibility shims from the previous spike.
