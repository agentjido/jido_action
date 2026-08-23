# Contributing to Jido Action

Thank you for your interest in contributing to Jido Action! This document provides guidelines for contributing to the project.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Install dependencies: `mix deps.get`
4. Run tests: `mix test`
5. Run quality checks: `mix quality`

## Development Workflow

1. Create a feature branch from `main`
2. Make your changes
3. Add tests for new functionality
4. Ensure all tests pass: `mix test`
5. Run quality checks: `mix quality`
6. Submit a pull request

## Code Style

- Follow the existing code style and patterns
- Use `mix format` to format your code
- Ensure Dialyzer passes: `mix dialyzer`
- Follow Credo guidelines: `mix credo`

## Security Scanning

The project includes automated security scanning to detect dependency vulnerabilities and code-level security issues.

### Local Security Scans

Run security checks locally before submitting:

```bash
# Check for dependency vulnerabilities
mix deps.audit

# Run all quality checks including security
mix quality
```

### CI Security Checks

The CI pipeline automatically runs:
- **Dependency audit**: Scans for known vulnerabilities in dependencies using `mix_audit`
- **CodeQL analysis**: Static code analysis for security patterns and vulnerabilities

High-severity security findings will cause CI to fail. Address any security issues before merging.

## Testing

- Add tests for all new functionality
- Maintain existing test coverage
- Use property-based testing where appropriate
- Include integration tests for complex features

### Test Coverage Policy

This spike keeps coverage meaningful while iterating. All contributions should:

- Maintain or improve the overall coverage percentage
- Include comprehensive tests for new code paths
- Not introduce uncovered code without justification

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

- **@moduledoc**: All public modules must have module documentation explaining their purpose
- **@doc**: All public functions must have function documentation with parameters, returns, and examples
- **@spec**: All public functions must have type specifications
- **@typedoc**: Custom types must have type documentation
- **@moduledoc false**: Use for internal/private modules that shouldn't appear in generated docs

Check documentation coverage locally:
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

The hook will reject non-conforming commits, ensuring a clean changelog can be generated automatically.

## Pull Request Guidelines

- Provide a clear description of the changes
- Use commit messages following conventional commits
- Reference any related issues
- Include tests and documentation updates
- Ensure CI passes

## Questions?

Feel free to open an issue for questions or discussion about potential contributions.
