import Config

# Git hooks and git_ops configuration for conventional commits
# Only configure when the dependencies are actually available (dev environment)
if config_env() == :dev do
  config :git_hooks,
    auto_install: true,
    # git_hooks writes this value into the installed shell hook, so keep it
    # relative to the active worktree instead of capturing an absolute path.
    project_path: ".",
    verbose: true,
    hooks: [
      commit_msg: [
        tasks: [
          {:cmd, "mix git_ops.check_message", include_hook_args: true}
        ]
      ]
    ]

  config :git_ops,
    mix_project: JidoAction.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/jido_action",
    manage_mix_version?: true,
    manage_readme_version: "README.md",
    version_tag_prefix: "v",
    types: [
      feat: [header: "Features"],
      fix: [header: "Bug Fixes"],
      perf: [header: "Performance"],
      refactor: [header: "Refactoring"],
      docs: [hidden?: true],
      test: [hidden?: true],
      deps: [hidden?: true],
      chore: [hidden?: true],
      ci: [hidden?: true]
    ]
end

if config_env() == :test do
  config :git_hooks, auto_install: false
end
