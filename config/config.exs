import Config

if config_env() in [:dev, :test] do
  config :covenant,
    test_paths: [
      "test/jido_action/action_test.exs",
      "test/jido_authoring/config_test.exs",
      "test/jido_authoring/shared_module_test.exs",
      "test/jido_authoring/options_test.exs",
      "test/jido_expr_test.exs",
      "test/jido_expr/elixir_conformance_test.exs",
      "test/jido_expr/survivor_contract_test.exs",
      "test/jido_flow/expr_test.exs",
      "test/property/expression/expression_contract_test.exs",
      "test/jido_action/output_test.exs",
      "test/jido_action/inline_test.exs",
      "test/jido_action/inline_host_test.exs",
      "test/jido_flow/dsl/inline_action_test.exs",
      "test/jido_flow/dsl/inline_step_test.exs",
      "test/jido_action/validation_test.exs",
      "test/jido_action/open_validation_contract_test.exs",
      "test/jido_action/error_test.exs",
      "test/jido_exec/node/action_test.exs",
      "test/jido_exec/validation_contract_test.exs",
      "test/jido_exec/api_test.exs",
      "test/jido_exec/error_paths_test.exs",
      "test/jido_exec/portable_test.exs",
      "test/jido_exec/node/choice_test.exs",
      "test/jido_exec/rebuild_test.exs",
      "test/jido_exec/source_map_test.exs",
      "test/jido_exec/flow_execution_test.exs",
      "test/jido_exec/node/map_test.exs",
      "test/jido_exec/node/dispatch_test.exs",
      "test/property/action/boundary_contract_test.exs",
      "test/property/action/error_contract_test.exs",
      "test/jido_instruction/instruction_test.exs",
      "test/jido_instruction/target_test.exs",
      "test/property/instruction/call_contract_test.exs",
      "test/property/instruction/target_contract_test.exs"
    ]
end

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
