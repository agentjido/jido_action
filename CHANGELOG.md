# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
