# Upgrade From Version 2 To Version 3

Use this checklist when an application moves from Jido Action 2.x to 3.x.
Review the detailed [migration guide](v2-to-v3-migration.md) before you edit.

## Before You Start

- Keep the V2 package and application tests green.
- Record the current Action input, output, error, and effect behavior.
- Find every Exec call and every stored Instruction or workflow record.
- Decide which calls are immediate and which need durable Runic execution.

## Agent Prompt

```text
Upgrade this application from jido_action 2.x to 3.x.

Use Jido.Action with static Zoi input and output schemas.
Replace old Instruction fields with target, params, context, metadata, and kind.
Replace Jido.Plan or Action chains with Jido.Flow only when a reusable graph is needed.
Give every Flow an explicit output.
Use Jido.Exec.run/4 for immediate work.
Use Jido.Exec.compile/2 when native Runic inspection is needed.
Use Jido.Exec.start/6 with a supervised Runic.Runner for managed or durable work.
Use Runic.Runner for checkpoint, stop, resume, and results.
Do not add compatibility wrappers for removed async handles, step-wise Execution values, or root Action continuations.
Store Flow definitions with Jido.Flow.Codec and a trusted Registry.
Store runtime progress through the Runic Store contract.
Run format, compile, tests, property tests, documentation checks, Credo, and Dialyzer.
```

## Required Changes

1. Update the package requirement and lock file.
2. Convert Action schemas to static Zoi schemas.
3. Replace removed Action hooks and generated metadata functions.
4. Replace old Instruction fields and shorthand constructors.
5. Replace old Exec retry options with `max_attempts`, `backoff`,
   `base_delay_ms`, and `max_delay_ms`.
6. Replace async handle and step-wise Exec APIs with immediate Exec or managed
   Runic execution.
7. Replace root Action continuations with explicit Flow control components.
8. Convert stored workflow data to `Jido.Flow.Codec` documents and a trusted
   Registry.
9. Add durable recovery tests when execution must survive process loss.

## Review The Result

Confirm these facts:

- Every Action and Flow runs through a real Runic workflow.
- No application code depends on a Jido execution cursor or checkpoint.
- Durable work resumes through `Runic.Runner` and its Store.
- Stored Flow JSON cannot create atoms or select unregistered modules.
- Action and Flow output schemas still match the V2 application contract.
- Deferred effects have stable host deduplication keys when retries are enabled.
- All package and application checks pass.
