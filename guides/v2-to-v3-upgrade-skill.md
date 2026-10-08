# v2 To v3 Upgrade Skill

Use this page to hand a version 2 to version 3 upgrade to a coding agent. The
[migration guide](v2-to-v3-migration.md) holds the detailed changes and the
checklist. This page adds preparation steps, a prompt, and review checks.

## Before You Start

- Keep the version 2 package and application tests green.
- Record the current Action input, output, error, timeout, and retry behavior.
- Find every `Jido.Exec` call, every stored Instruction, Plan, or workflow
  record, and every `Jido.Action.TaskSupervisor` reference.
- Decide which calls run immediately and which need managed execution under a
  `Runic.Runner`.

## Agent Prompt

```text
Upgrade this application from jido_action 2.x to 3.0.0-beta.12.

Follow guides/v2-to-v3-migration.md in the jido_action package. Work through
its checklist one item at a time. Compile and run the tests after each item.

Rules:
- Use Jido.Action with static Zoi input and output schemas.
- Build Instructions with target, params, context, and metadata.
- Return effects only as a proper list in the third success element.
- Pass execution options to Jido.Exec.run/4. Set timeout: explicitly.
  Convert max_retries: n to max_attempts: n + 1, and only for idempotent work.
- Replace run_async/await/cancel with a supervised Task around run/4, or with
  Jido.Exec.start/6 under a supervised Runic.Runner for managed work.
- Replace Jido.Plan and Action chains with Jido.Flow only when a reusable
  graph is needed. Give every Flow an explicit output.
- Use Choice, Iterate, or Dispatch for control flow. Only a Dispatch expander
  may return {:continue, input, target}.
- Use Runic.Runner for checkpoint, stop, resume, and results.
- Store Flow definitions with Jido.Flow.Codec and an application-owned
  Jido.Flow.Registry. Store runtime progress through the Runic Store.
- Do not add compatibility wrappers for removed version 2 APIs.

Finish by running format, compile with warnings as errors, the full test
suite, Credo, and Dialyzer.
```

## Review The Result

Confirm these facts:

- Every checklist item in the migration guide is done or does not apply.
- No code calls a removed version 2 function, hook, or Instruction field.
- Every `Jido.Exec.run/4` call that needs a time limit passes `timeout:`.
- Retries (`max_attempts` above `1`) apply only to idempotent work.
- Durable work resumes through `Runic.Runner` and its Store.
- Stored Flow JSON cannot create atoms or select unregistered modules.
- Action output schemas still match the version 2 application contract.
- Flows that replace Plans or Chains return the same final output.
- Deferred effects have stable deduplication keys when retries are enabled.
