# AGENTS.md - Jido.Action Guide

## Intent
Build composable, validated actions that can run standalone or through Jido execution policies.

## Runtime Baseline
- Elixir `~> 1.18`
- OTP `27+` (release QA baseline)

## Commands
- `mix test` (default alias excludes `:flaky`)
- `mix test --include flaky` (full suite)
- `mix q` or `mix quality` (`format --check-formatted`, `compile --warnings-as-errors`, `credo`, `dialyzer`)
- `mix coveralls.html` (coverage report)
- `mix docs` (local docs)

## Architecture Snapshot
- `Jido.Action`: action behavior/macro and metadata contract
- `Jido.Exec`: sync/async execution, retries, timeout, cancellation
- `Jido.Instruction`: normalized action envelope (`action`, `params`, `context`)
- `Jido.Plan`: DAG workflow planning/execution
- `Jido.Action.Tool` and `Jido.Tools.*`: LLM tool bridge and built-in actions
- Instance isolation via `jido:` option and instance-scoped supervisors

## Standards
- Use **Zoi-first** schemas for new actions; keep NimbleOptions for compatibility paths only
- Keep `run/2` return contracts strict: `{:ok, result}` or `{:error, reason}`
- Route production execution through `Jido.Exec` when retry/timeout/telemetry policy matters
- Keep side effects explicit and isolated
- Add concise `@moduledoc`, public `@doc`, and `@spec` for public APIs

## Testing and QA
- Test schema validation, success path, and error path independently
- For async behavior, assert task/mailbox cleanup semantics instead of timing guesses
- Avoid log-only assertions unless log output is part of the contract

## Release Hygiene
- Keep semver ranges stable (`~> 2.0` for Jido ecosystem peers)
- Use Conventional Commits
- Update `CHANGELOG.md` and docs for behavior/API changes

## References
- `README.md`
- `usage-rules.md`
- `guides/`
- https://hexdocs.pm/jido_action
