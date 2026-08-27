# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `v3.0.0-beta.1` entry is maintained by hand because the development
history between v2 and v3 is not a reliable release boundary. Later release
entries return to the normal automated changelog process.

<!-- changelog -->

## Unreleased

## [v3.0.0-beta.2](https://github.com/agentjido/jido_action/compare/v3.0.0-beta.1...v3.0.0-beta.2) (2026-08-27)

### Features:

* add generated temporary Flow registries through
  `Jido.Flow.Registry.from_flow/1` and `Jido.Flow.Codec.encode/1`
* accept deprecated `Jido.Instruction.action` constructor and struct input with
  a runtime migration warning, and normalize typed `action` and `flow` inputs
  to the canonical `target` field
* accept deprecated `Jido.Instruction.opts` input with grouped runtime warnings,
  forward `timeout` and `jido`, and report removed or unknown version 2 settings

### Documentation:

* add a package-wide migration shim guide with warning behavior, design rules,
  active shims, deliberate non-shims, and migration steps

### Refactoring:

* organize the `Jido.Exec` implementation into focused Action, Flow, runtime,
  and telemetry modules
* remove the separate Exec supervisor and custom concurrency limiter, and use
  Runic ready-wave scheduling with the configured Task Supervisor
* centralize internal execution telemetry under `Jido.Exec.Telemetry`, close
  active spans after finite timeouts, and add complete types to Execution data

## [v3.0.0-beta.1](https://github.com/agentjido/jido_action/compare/v2.3.2...v3.0.0-beta.1) (2026-08-25)

### Features:

* add the declarative, compile-time Jido Flow module DSL
* add direct Flow constructors, runtime Builder authoring, and one canonical
  `%Jido.Flow{}` data model
* add step, choice, map, reduce, iterate, and derived Subflow forms
* compile canonical Jido Flows into native Runic workflows
* expose native Runic Runnable values for step-wise Flow execution
* add dependency-aware parallel Flow execution and run-to-completion execution
* add portable, versioned Map and JSON storage with a trusted host Registry
* add aggregate stored-Flow diagnostics for browser and AI authoring tools
* add a Splode-based `Jido.Flow.Error` boundary for Flow definition,
  compilation, and execution failures
* let `Jido.Instruction` target Actions, Flow modules, and runtime Flows through
  `Jido.Executable`
* route Action, Instruction, Flow, and Subflow workers through a running Jido
  instance Task Supervisor with the common `jido:` option
* add stable Action, Flow, Flow-node, and collection telemetry lifecycles

### Breaking Changes:

* replace the earlier Flow authoring syntax with one declarative DSL
* replace the Jido node-result scheduler with the native Runic execution surface
* replace `MapResult` with ordered Map list output at scalar boundaries
* replace `Jido.Flow.Iterator` with `Jido.Flow.Iterate`
* replace the `Jido.Instruction.action` field with the executable-neutral
  `Jido.Instruction.target` field
* remove `Jido.Exec.FlowFailureError`; multiple runnable failures now use
  `Jido.Flow.Error.ExecutionFailureError`
* move the root, Task, and concurrency supervisors under the `Jido.Exec`
  namespace
* remove the stored Elixir Flow source parser; stored Flows now use Map or JSON
  data
* remove the legacy `Jido.Action.Catalog`, `Jido.Action.Tool`, `Jido.Plan`,
  `Jido.Tools.*`, retry, compensation, and propagation APIs
* require Elixir `~> 1.20`

### Bug Fixes:

* preserve target error paths and add Flow node phase and ownership details to
  returned standard exceptions
* report invalid reference scopes through the canonical expression validator
* compile the exact Flow returned by `flow/0` during execution instead of
  trusting an independent `compiled/0` result
* preserve deterministic collection ordering, failure details, and runtime
  context
* keep stored Map validation inert, bounded, non-raising, and safe for
  correction loops
* reject invalid UTF-8 and over-limit data before the stored writer returns a
  map
* use one canonical constructor for the DSL, Builder, direct data, and stored
  Flow maps
* return structured validation errors for improper runtime lists and reject
  negative reference path indexes
* reject stale step-wise execution values before a second Action dispatch

### Documentation:

* state the in-memory Flow, internal graph engine, and durable orchestration
  boundaries
* define the restricted Flow expression grammar and source-to-data names
* add a verified v3 migration guide and a complete task-based guide set
* document exact telemetry events, runtime Map validation, debugging, and
  step-wise execution semantics
* restore package status badges and direct links to the Jido ecosystem
* record the v2-to-v3 release entry by hand because the development history is
  not a reliable release boundary

## [v2.3.2](https://github.com/agentjido/jido_action/compare/v2.3.1...v2.3.2) (2026-08-07)

### Bug Fixes:

* update Mint for CVE-2026-59249
* relax the optional Lua dependency constraint

## [v2.3.1](https://github.com/agentjido/jido_action/compare/v2.3.0...v2.3.1) (2026-06-09)




### Bug Fixes:

* simplify telemetry struct message handling by mikehostetler

* satisfy Elixir 1.20 telemetry type checks by mikehostetler

* security: harden built-in tool boundaries (#185) by mikehostetler

* update LuaEval for Lua.ex 1.0 compatibility by mikehostetler

## [v2.3.0](https://github.com/agentjido/jido_action/compare/v2.2.1...v2.3.0) (2026-05-22)




### Features:

* add canonical catalog merge by mikehostetler

* add action catalog data structures by mikehostetler

### Bug Fixes:

* recursively convert nested Zoi tool params by mikehostetler

* harden action error JSON encoding (#158) by mikehostetler

* preserve runtime context across supervised execution (#156) by mikehostetler

* migrate plan graph usage to multigraph (#150) by mikehostetler

* derive Jason.Encoder for error structs (#147) by ryan-mckeeman-cfgi

* repo: make git_hooks auto-install work across worktrees (#145) by mikehostetler

* exec: normalize struct error details (#134) by mikehostetler

* compat: clean up Elixir 1.20 compatibility by mikehostetler

### Refactoring:

* fix ex_slop findings by Danila Poyarkov

* exec: align canonical observability contract (#140) by nshkrdotcom

## [v2.2.1](https://github.com/agentjido/jido_action/compare/v2.2.0...v2.2.1) (2026-04-03)




### Bug Fixes:

* remove @spec from default callback implementations in __using__ macro (#133) by Philip Munksgaard

* remove @spec from default callback implementations in __using__ macro by Philip Munksgaard

* normalize non-exception errors in `handle_action_result` (#132) by Julian Scheid

* normalize non-exception errors in handle_action_result by Julian Scheid

## [v2.2.0](https://github.com/agentjido/jido_action/compare/v2.1.1...v2.2.0) (2026-03-28)




### Features:

* complete spec-led migration (#127) by mikehostetler

* add AI error envelope helpers by mikehostetler

### Refactoring:

* make action error maps generic (#126) by mikehostetler

* make action error maps generic by mikehostetler

## [v2.1.1](https://github.com/agentjido/jido_action/compare/v2.1.0...v2.1.1) (2026-03-14)




### Bug Fixes:

* switch libgraph to the published multigraph fork (#122) by mikehostetler

* deps: switch libgraph to multigraph fork by mikehostetler

## [v2.1.0](https://github.com/agentjido/jido_action/compare/v2.0.0...v2.1.0) (2026-03-14)




### Features:

* schema: support plain JSON Schema maps as action schemas (#108) by Danila Poyarkov

* schema: support plain JSON Schema maps as action schemas by Danila Poyarkov

### Bug Fixes:

* lockfile: remove unused dependencies by mikehostetler

* prevent struct corruption during telemetry depth truncation (#120) by Edgar Gomes

* prevent struct corruption during telemetry sanitization depth truncation by Edgar Gomes

* preserve sanitization for deep telemetry structs by Edgar Gomes

* release: hide deps commits from git_ops changelog by mikehostetler

* sanitize telemetry struct map keys (#117) by mikehostetler

* telemetry: sanitize non-scalar map keys by mikehostetler

* ci: isolate beam cache per toolchain by mikehostetler

* schema: harden json-schema key handling and add parity coverage by Danila Poyarkov

* ci: clear changelog guard and dialyzer warnings by Danila Poyarkov

* safe inspect struct truncation (#107) by roeeyn

* sanitize struct truncation by roeeyn

* preserve telemetry __struct__ compatibility by roeeyn

* exec: keep sanitized structs inspect-safe (#103) by pcharbon70

### Refactoring:

* tools: remove api-specific tool packs from core (#118) by mikehostetler

* tools: remove api-specific tool packs from jido_action by mikehostetler

## [v2.0.0](https://github.com/agentjido/jido_action/compare/v2.0.0-rc.5...v2.0.0) (2026-02-22)

### Release Notes:

* promote the 2.0.0 release candidate line to stable 2.0.0

### Features:

* add Igniter installer for automated package setup (#102)

### Bug Fixes:

* repair usage rules and doctor gate checks
* add opt-in recursive strict JSON schema for tools (#101)

### Changed:

* require Elixir ~> 1.18
* update installation docs to use `{:jido_action, "~> 2.0"}`

## [v2.0.0-rc.5](https://github.com/agentjido/jido_action/compare/v2.0.0-rc.4...v2.0.0-rc.5) (2026-02-16)




### Features:

* tools: add github pulls comments and webhooks actions by mikehostetler

### Bug Fixes:

* timeout: propagate execution deadlines across nested tools (#99) by mikehostetler

* retry: harden retry policy and suppress nested retries (#96) by mikehostetler

* telemetry: sanitize metadata and logs (#98) by mikehostetler

* async: enforce owner-only await and cancel (#97) by mikehostetler

* error: normalize workflow/action-plan/lua/weather leaf error contracts (#95) by mikehostetler

* exec: align changelog with base branch by mikehostetler

* tools: remove changelog edit from luaeval supervision PR by mikehostetler

* exec: remove changelog edit from async cancel PR by mikehostetler

* exec: format config fallback test and drop changelog delta by mikehostetler

* exec: guard invalid runtime timeout and retry defaults with safe fallbacks by mikehostetler

* tools: run lua eval tasks under Task.Supervisor without caller linkage by mikehostetler

* exec: cleanup async cancel monitor and mailbox residue by mikehostetler

* workflow: add parallel timeout and strict failure policy controls by mikehostetler

* exec: cleanup compensation monitor and timeout race leakage by mikehostetler

* exec: eliminate async await monitor and mailbox leakage by mikehostetler

* exec: run async chains under Task.Supervisor without caller linkage by mikehostetler

* plan: reject undefined dependency steps during normalization by mikehostetler

### Refactoring:

* tools: centralize github client and response helpers by mikehostetler

## [2.0.0-rc.4] - 2026-02-06

### Added
- **Skills**: Add hex-release skill for interactive Hex package management

### Changed
- **Deps**: Remove quokka dependency (#66)

## [2.0.0-rc.3] - 2025-02-04

### Added
- **Geocode**: Add geocode tool for weather location lookup (#58)

### Fixed
- **Compensation**: Handle normal exit race condition for in-flight result message (#64)
- **Exec**: Avoid `Task.yield` in `execute_action_with_timeout` - replace with explicit messaging
- **Schema**: Return valid JSON Schema for empty schemas

### Changed
- **Deps**: Update dependencies and fix Mimic async test

## [2.0.0-rc.2] - 2025-01-30

### Fixed
- **Compensation**: Use supervised tasks and pass opts to `on_error/4` callback (#57)
- **Tool**: Support atom keys and preserve unknown keys in `Tool.convert_params_using_schema` (#56)

### Added
- **Instance Isolation**: Add `jido:` option for multi-tenant execution with instance-scoped supervisors (#54)
- **Workflow**: Implement true parallel execution with `Task.Supervisor` (#50)
- **Exec**: Add task_supervisor injection for OTP instance support

### Changed
- **Workflow**: Switch `async_stream_nolink` to `async_stream` for better error handling
- **Core**: Extract helper functions and reduce macro complexity

### Removed
- Remove unused `typed_struct` dependency (#55)

## [2.0.0-rc.1] - 2025-01-29

### Added
- Major 2.0 release candidate with breaking changes
- Zoi schema support for improved validation
- Enhanced error handling with Splode

## [1.0.0] - 2025-01-29

### Added
- Initial release of Jido Action framework
- Composable action system with AI integration
- Execution engine with sync/async support
- Built-in tools for common operations
- Plan system for DAG-based workflows
- Comprehensive testing framework
- AI tool conversion capabilities
- Error handling and compensation system
