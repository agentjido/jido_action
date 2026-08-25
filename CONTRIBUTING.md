# Contributing To Jido Action

Thank you for your interest in Jido Action. This document gives the rules for
contributions.

## Getting Started

1. Fork the repository.
2. Clone your fork.
3. Install dependencies with `mix deps.get`.
4. Run tests with `mix test`.
5. Run quality checks with `mix quality`.
6. Run the dependency audit with `mix deps.audit`.

## Development Workflow

1. Create a branch from `main`.
2. Make your changes.
3. Add tests for new behavior.
4. Run `mix test`.
5. Run `mix quality`.
6. Run `mix deps.audit`.
7. Submit a pull request.

## Code Style

- Follow the existing code style and patterns
- Use `mix format` to format your code
- Ensure Dialyzer passes: `mix dialyzer`
- Follow Credo guidelines: `mix credo`

## Security Scanning

The project includes checks for dependency vulnerabilities and code security
problems.

### Local Security Scans

Run security checks locally before submitting:

```bash
mix deps.audit
```

### CI Security Checks

The CI pipeline runs the configured dependency and code security checks.

High-severity security findings will cause CI to fail. Address any security issues before merging.

## Testing

- Add tests for all new functionality
- Maintain existing test coverage
- Use property-based testing where appropriate
- Add an integration test when a contract crosses a package or OTP boundary.

### Test Coverage Policy

The test suite enforces a 93 percent total coverage floor. All contributions
must:

- Keep the coverage check at or above the configured floor.
- Include direct tests for new behavior.
- Give a reason for code that cannot have a direct test.

Check coverage locally:

```bash
mix test --cover
```

## Documentation

- Update documentation for any API changes
- Add examples for new features
- Update guides if adding new concepts
- Ensure `mix docs` builds without errors

### Documentation Standards

All public APIs must be properly documented:

- Use `@moduledoc` for each public module.
- Use `@doc` for each public function.
- Add examples where they help a developer complete a task.
- Use `@spec` for public function contracts.
- Use `@typedoc` for public custom types.
- Use `@moduledoc false` for internal modules.

Check the documentation locally:

```bash
mix docs --warnings-as-errors
```

Documentation generation must complete without warnings.

## Git Hooks and Conventional Commits

We use [`git_hooks`](https://hex.pm/packages/git_hooks) to enforce commit message conventions:

```bash
mix deps.compile git_hooks --force
```

The repo auto-installs a fast `commit-msg` hook when `git_hooks` compiles in `:dev`. The command above is the explicit refresh path for existing clones and worktrees when you want to rewrite the installed hook immediately.

If your local `.git/hooks/commit-msg` script still `cd`s into an old absolute checkout path, rerun the command above once. The installed hook is generated relative to the active worktree so it works from the main checkout, linked worktrees, and detached worktrees.

Local hook enforcement intentionally stays small and fast: only `commit-msg` runs locally. Test and quality checks remain enforced in GitHub Actions.

### Commit Message Format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | A new feature |
| `fix` | A bug fix |
| `improvement` | A general improvement that is not a feature or fix |
| `build` | Changes to build tooling or packaging |
| `docs` | Documentation only changes |
| `style` | Changes that don't affect code meaning |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or correcting tests |
| `chore` | Changes to build process or auxiliary tools |
| `ci` | CI configuration changes |
| `deps` | Dependency updates |

### Examples

```bash
# Feature
git commit -m "feat(actions): add new action directive"

# Bug fix
git commit -m "fix(runner): resolve timeout handling"

# Breaking change
git commit -m "feat(api)!: change action schema"
```

The hook rejects non-conforming commits and keeps the repository history easy
to read. Maintainers update `CHANGELOG.md` by hand for each release.

## Pull Request Guidelines

- Provide a clear description of the changes
- Use commit messages following conventional commits
- Reference any related issues
- Include tests and documentation updates
- Ensure CI passes

## Questions?

Feel free to open an issue for questions or discussion about potential contributions.
