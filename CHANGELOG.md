# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- changelog -->

## [Unreleased]

### Changed:

* narrow `jido_action` to core and generic built-in tools and direct vendor/API-specific packs to `jido_lib`
* move the Zoi sample action to `Jido.Examples.ZoiExample`

### Removed:

* built-in GitHub, Weather, and Simplebot tool packs from `jido_action`
* `:tentacat` and `:weather` dependencies from the package
* toolpack-specific tests and helper mocks tied to the removed integrations

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
