# Upgrade From v2 To v3 Skill

Use this prompt with an AI coding agent to upgrade an Elixir application from
`jido_action` v2 to v3. The prompt uses the published `v2.3.2` release as the
v2 baseline.

Read [Upgrade From v2 To v3](v3-migration.md) before you use the prompt. The
migration guide explains the API decisions and the required replacements.
Read [Migration Shims](migration-shims.md) for the package-wide compatibility
policy. Do not treat a supported shim as the preferred version 3 API.

## Before You Start

Give the agent access to the application repository. Start from a clean branch
or record all current changes. The agent must preserve changes that are not
part of the upgrade.

Decide which v3 release you want. The prompt below uses `3.0.0-beta.2`, which
requires Elixir 1.18 or later.

## Agent Prompt

Copy this complete prompt into your coding agent:

```text
Upgrade this Elixir application from jido_action v2 to
jido_action 3.0.0-beta.2.

Use the published jido_action v2.3.2 API as the v2 baseline. Do not use an
unpublished Flow spike or a mid-development v3 API as the baseline. Version 2
has Jido.Action, Jido.Instruction, Jido.Exec, Jido.Plan, Action catalogs,
Action tools, and bundled tools. Version 2 does not have Jido.Flow.

Read the current jido_action v3 upgrade guide and the installed v3 module
documentation before you edit code. Inspect this application first. Preserve
all current user changes and all behavior that is outside this upgrade.

Work in these stages.

1. Record the baseline

- Show the current branch and working-tree state.
- Find the jido_action requirement and locked version.
- Find the Elixir and OTP requirements and the CI matrix.
- Run the existing test and quality commands before edits when they can run.
- Record failures that already exist. Do not attribute them to the upgrade.

2. Build an upgrade inventory

Search all source, test, configuration, and documentation files for these v2
surfaces:

- Jido.Action options: category, tags, vsn, compensation, schema, and
  output_schema;
- Action lifecycle callbacks and generated metadata or tool functions;
- NimbleOptions Action schemas and dynamic Zoi schemas;
- Jido.Instruction fields, constructors, normalization, tuple shorthand, and
  allowlist calls;
- Jido.Exec runtime options, asynchronous handles, retries, cancellation,
  context propagation, Chains, and Closures;
- Jido.Plan and PlanInstruction;
- Jido.Action.Catalog and its Entry, Hit, and Query types;
- Jido.Action.Tool, Jido.Tools.*, and Jido.Tools.ActionPlan;
- old Mix tasks and code-generation commands;
- direct references to JidoAction.Supervisor or
  Jido.Action.TaskSupervisor; and
- application configuration under :jido_action.

Report the inventory before large edits. Separate mechanical changes from
changes that need an application policy decision. Continue with changes that
have one clear result. Ask for a decision only when different choices would
change application behavior.

3. Update the package and platform

- Change the dependency to {:jido_action, "~> 3.0.0-beta.2"}.
- Set the application to Elixir 1.18 or later for `3.0.0-beta.2`.
- Update CI to test the selected Elixir and OTP versions.
- Run mix deps.get.
- Add direct dependencies for libraries that the application used only
  because jido_action v2 supplied them. Examples include Jason,
  NimbleOptions, Req, Lua, Multigraph, and Igniter.

4. Migrate Actions

- Keep name, description, schema, output_schema, and run/2.
- Remove category, tags, vsn, and compensation from use Jido.Action.
- Move application metadata to application-owned modules or plain functions
  when it is still needed.
- Convert each NimbleOptions Action schema to a map-shaped Zoi schema.
- Keep [] only when the Action intentionally has no declared schema.
- Make schemas static module data. Replace anonymous or lazy schema effects
  with named MFA effects.
- Remove on_before_validate_params/1, on_after_validate_params/1,
  on_before_validate_output/1, on_after_validate_output/1, on_after_run/1,
  and on_error/4.
- Put schema transformations in Zoi. Put Action work in run/2. Put retry,
  rollback, and compensation policy in the caller or its runtime.
- Replace category/0, tags/0, vsn/0, to_json/0, to_tool/0, and
  __action_metadata__/0 call sites.
- Do not expect Jido.Exec to add :action_metadata to context.
- Keep the supported two-tuple and three-tuple Action callback results.
- Use Jido.Action.Output only when success data is intentionally raw, batch,
  stream, or opaque.

5. Migrate Instructions

- Replace the action field with target. Version 3 accepts an action constructor
  key or struct field as a temporary migration input, emits a runtime warning,
  and normalizes it to target.
- Move descriptive id data to metadata or to caller-owned data.
- Remove opts from the Instruction. Version 3 accepts this field as a temporary
  migration shim and emits a runtime warning. It forwards timeout and jido,
  but it does not apply removed version 2 settings. Pass execution policy to
  Jido.Exec.run/4.
- Keep params and context as maps.
- Replace normalize/3, normalize_single/3, tuple shorthand, list shorthand,
  and validate_allowed_actions/2 with explicit new/1 or new!/1 calls and an
  application-owned allowlist.
- Remember that a v3 target can be an Action module, a Flow module, or a
  runtime Jido.Flow value.

6. Migrate execution policy

- Keep Jido.Exec.run/4 as the normal execution boundary.
- Note that its default timeout changed from 30 seconds to :infinity. Select
  and pass an explicit timeout when the application needs a limit.
- Remove max_retries, backoff, log_level, telemetry,
  context_propagators, context_propagator_failure_mode, and
  error_normalization from Exec options.
- Replace run_async/4, await/2, and cancel/1 with caller-owned Task or runtime
  policy when asynchronous execution is still required.
- Move retry count, backoff, deadline, cancellation, and compensation to the
  caller. Preserve idempotency rules.
- Keep jido: instance routing. Confirm that the selected instance Task
  Supervisor is running.
- Use async and max_concurrency only for Flow scheduling. Flow async does not
  return a v2 asynchronous handle.

7. Replace Plans and Chains only where needed

- Treat Jido.Flow as a new v3 API. Do not rename unpublished Flow-spike fields.
- Replace a reusable or executable Jido.Plan DAG with a Flow module, runtime
  Builder Flow, or direct canonical Flow.
- Give every Flow one explicit output.
- Use result references for data dependencies.
- Use after only for required order that has no data reference.
- Pass runtime context to Jido.Exec or an Instruction. Do not store runtime
  context in the Flow definition.
- Do not reproduce the implicit parameter merge from Jido.Exec.Chain. Define
  each Flow step input with input, context, result, and select references.
- Use Enum.reduce_while with Jido.Exec.run when the old Chain was only a
  dynamic sequential loop and a reusable graph adds no value.
- Replace Jido.Exec.Closure with an ordinary application function.

8. Replace removed package concerns

- Move Action catalog search, discovery, visibility, and merge policy to the
  application or its owning package.
- Do not use Jido.Flow.Registry as a replacement for Jido.Action.Catalog.
  Registry is only a trusted identifier lookup for Jido.Flow.Codec.
- Move AI tool conversion out of jido_action. Build the adapter from Action
  name, description, schema, and Jido.Exec.run/4.
- Replace Jido.Tools.* with application Actions or the package that owns each
  integration.
- Remove calls to the old Action, workflow, and install Mix tasks.

9. Migrate errors, supervisors, and storage

- Keep valid matches on the concrete Jido.Action.Error exception types.
- Do not expect Jido.Exec to retry an error. Treat details.retry as
  information for the caller.
- Use Jido.Flow.Error for Flow definition and Flow execution failures.
- Use Jido.Action.Error.to_map/1 or Jido.Flow.Error.to_map/1 at JSON, HTTP,
  log, and UI boundaries.
- Replace Jido.Action.TaskSupervisor with Jido.Exec.TaskSupervisor for the
  global execution supervisor.
- Do not depend on the package root supervisor name. Use
  Jido.Exec.TaskSupervisor when direct Task Supervisor access is required.
- Keep MyApp.Jido.TaskSupervisor for jido: MyApp.Jido instance routing.
- Treat the v3 stored Flow document as a new format. Do not decode v2 Plan,
  Instruction, Action JSON, or development-spike data with Jido.Flow.Codec.
- Use Jido.Flow.Codec with a trusted Jido.Flow.Registry for stored Flows.

10. Verify the result

- Format all changed Elixir files.
- Compile with warnings as errors.
- Run the complete test suite and the repository quality command.
- Test Action input validation, output validation, two-tuple and three-tuple
  results, exceptions, throws, exits, and timeouts.
- Test each migrated Flow for validation, dependency order, result data,
  complete execution, and step-wise execution when the application uses it.
- Round-trip stored Flows through real JSON bytes and the trusted Registry.
- Confirm that no removed v2 module, callback, field, option, configuration
  key, or supervisor name remains unless it is in migration documentation.
- Review the final diff for unrelated edits and accidental compatibility
  layers.

Do not add aliases or silent fallbacks for removed v2 APIs unless the
application has an explicit compatibility requirement. Do not commit, push,
tag, publish, deploy, or change external services unless I request that action.

At the end, report:

- the v2 API use that you found;
- the code and configuration that you changed;
- each behavior decision and its reason;
- unresolved application choices;
- test and quality results; and
- any remaining release risk.
```

## Review The Result

The prompt gives the agent a migration procedure. It cannot select your
application policy for retry, compensation, cancellation, AI tools, or catalog
search. Review those choices before you release the upgraded application.

The final application must not depend on an implicit conversion from v2 Plan
or Chain data. A v3 Flow must show its data references and required output.
