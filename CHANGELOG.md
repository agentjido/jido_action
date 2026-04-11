# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- changelog -->

## Unreleased

### Bug Fixes:

* rename `Graph` plan references to `Multigraph` and bump `multigraph` to `~> 0.16.1-mg.3` to avoid downstream release conflicts with `libgraph`

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

## [2.1.0](https://github.com/agentjido/jido_action/compare/v2.0.0...2.1.0) (2026-03-14)




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
