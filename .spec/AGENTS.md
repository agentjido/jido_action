# `.spec` Agent Guide

Use this folder to maintain authored Spec Led Development subjects and generated state.

<!-- covers: spec.workspace.agents_present -->

## First Read

1. Read `.spec/README.md`.
2. Read `.spec/decisions/*.md` when the work changes repo-wide policy or multiple subjects.
3. Read the current `.spec/specs/*.spec.md` files before editing.

## Working Rules

- Keep `.spec` declarative and current-state only.
- Use Git history, not `.spec`, to explain how a change evolved over time.
- Add or update an ADR only for a durable cross-cutting decision.
- Keep one subject per file.
- Put normative statements in `spec-requirements`.
- Add `spec-scenarios` only when `given` / `when` / `then` improves clarity.
- Prefer targeted command verifications for behavioral proof.
- Use file-backed verifications only when the target can carry stable `covers:` markers for every covered id.
- Keep package specs pointed at smaller subject files rather than one umbrella spec when the runtime surface is broad.
- Keep verification targets repository-root-relative.
- Finish with `mix spec.verify --debug` and `mix spec.check`.
