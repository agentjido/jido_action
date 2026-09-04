defmodule JidoAction.MixProject do
  use Mix.Project

  @version "3.0.0-beta.5"
  @source_url "https://github.com/agentjido/jido_action"
  @description "Validated actions, call frames, and data-first Flow composition for Elixir"

  def vsn do
    @version
  end

  def project do
    [
      app: :jido_action,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),

      # Docs
      name: "Jido Action",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      test_coverage: [
        # Test support compiles into the test application but is not product code.
        ignore_modules: [
          ~r/^Inspect\.JidoActionTest\./,
          ~r/^JidoActionTest\./,

          # Spark owns this generated namespace. Handwritten DSL and compiler
          # modules remain part of the coverage result.
          ~r/^Jido\.Flow\.DSL\.Extension\.Flow\./,

          # Inline wrappers contain generated Action scaffolding only.
          ~r/^Jido\.Flow\.Generated\.InlineStep\./,
          ~r/^Jido\.Action\.Generated\.Inline\./
        ],
        summary: [threshold: 93]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      registered: [Jido.Exec.TaskSupervisor],
      mod: {Jido.Action.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "bench"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      api_reference: true,
      source_ref: "v#{@version}",
      source_url: "https://github.com/agentjido/jido_action",
      authors: ["Mike Hostetler <mike.hostetler@gmail.com>"],
      groups_for_extras: [
        Project: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        "Start Here": [
          "guides/getting-started.livemd",
          "guides/build-your-first-flow.livemd"
        ],
        "Core Contracts": [
          "guides/actions.md",
          "guides/instructions.md",
          "guides/flows.md",
          "guides/continuations.md",
          "guides/schemas-validation.md",
          "guides/execution.md"
        ],
        "Author Flows": [
          "guides/flow-language.livemd",
          "guides/flow-steps.livemd",
          "guides/flow-references.livemd",
          "guides/flow-expressions.md",
          "guides/flow-dependencies.livemd",
          "guides/flow-choices.livemd",
          "guides/flow-collections.livemd",
          "guides/flow-iterate-state.livemd",
          "guides/nested-flows.livemd",
          "guides/flow-modules.md",
          "guides/flow-builder.md",
          "guides/flow-storage.md",
          "guides/flow-inspection.md"
        ],
        "Run And Operate": [
          "guides/flow-execution.livemd",
          "guides/debugging-flows.md",
          "guides/configuration.md",
          "guides/security.md",
          "guides/testing.md"
        ],
        Upgrade: [
          "guides/v2-to-v3-migration.md",
          "guides/migration-shims.md",
          "guides/v2-to-v3-upgrade-skill.md"
        ]
      ],
      extras: [
        # Project
        {"README.md", title: "Home"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "Apache 2.0 License"},
        # Start Here
        {"guides/getting-started.livemd", title: "Getting Started"},
        {"guides/build-your-first-flow.livemd", title: "Build Your First Flow"},
        # Core Contracts
        {"guides/actions.md", title: "Actions"},
        {"guides/instructions.md", title: "Instructions"},
        {"guides/flows.md", title: "Flows"},
        {"guides/continuations.md", title: "Terminal Transitions"},
        {"guides/schemas-validation.md", title: "Schemas & Validation"},
        {"guides/execution.md", title: "Execution Contract"},
        # Author Flows
        {"guides/flow-language.livemd", title: "Flow DSL"},
        {"guides/flow-steps.livemd", title: "Steps And Output"},
        {"guides/flow-references.livemd", title: "References And Data"},
        {"guides/flow-expressions.md", title: "Expressions And Host DSLs"},
        {"guides/flow-dependencies.livemd", title: "Dependencies And Parallel Work"},
        {"guides/flow-choices.livemd", title: "Choices And Conditions"},
        {"guides/flow-collections.livemd", title: "Map And Reduce"},
        {"guides/flow-iterate-state.livemd", title: "Iterate And State"},
        {"guides/nested-flows.livemd", title: "Nested Flows"},
        {"guides/flow-modules.md", title: "Flow Modules"},
        {"guides/flow-builder.md", title: "Direct Construction And Builder"},
        {"guides/flow-storage.md", title: "Store Flows As JSON"},
        {"guides/flow-inspection.md", title: "Inspect Flows"},
        # Run And Operate
        {"guides/flow-execution.livemd", title: "Executing Flows"},
        {"guides/debugging-flows.md", title: "Debug Flows"},
        {"guides/configuration.md", title: "Runtime Configuration"},
        {"guides/security.md", title: "Security"},
        {"guides/testing.md", title: "Testing"},
        # Upgrade
        {"guides/v2-to-v3-migration.md", title: "Version 2 To Version 3 Migration"},
        {"guides/migration-shims.md", title: "Migration Shims"},
        {"guides/v2-to-v3-upgrade-skill.md", title: "Upgrade From v2 To v3 Skill"}
      ],
      extra_section: "Guides",
      formatters: ["html"],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Action API": [
          Jido.Action,
          Jido.Action.Output
        ],
        "Executable API": [
          Jido.Executable,
          Jido.Instruction
        ],
        "Flow API": [
          Jido.Flow,
          Jido.Flow.Builder,
          Jido.Flow.Codec,
          Jido.Flow.Registry
        ],
        "Expression API": [Jido.Expr, Jido.Expr.Error],
        "Flow Types": [
          Jido.Flow.Choice,
          Jido.Flow.Choice.Option,
          Jido.Flow.Choice.Fallback,
          Jido.Flow.Component,
          Jido.Flow.Condition,
          Jido.Flow.Data,
          Jido.Flow.Dispatch,
          Jido.Flow.Expression,
          Jido.Flow.Iterate,
          Jido.Flow.Iterate.State,
          Jido.Flow.Map,
          Jido.Flow.Reduce,
          Jido.Flow.Ref,
          Jido.Flow.Step,
          Jido.Flow.Subflow
        ],
        "Flow Compilation": [
          Jido.Flow.Compiled
        ],
        Execution: [
          Jido.Exec,
          Jido.Exec.Execution
        ],
        Errors: [
          Jido.Action.Error,
          Jido.Action.Error.ConfigurationError,
          Jido.Action.Error.ExecutionFailureError,
          Jido.Action.Error.InternalError,
          Jido.Action.Error.InvalidInputError,
          Jido.Action.Error.TimeoutError,
          Jido.Exec.Error,
          Jido.Exec.Error.AsyncExecutionError,
          Jido.Exec.Error.AsyncTimeoutError,
          Jido.Exec.Error.CancelledError,
          Jido.Exec.Error.InvalidHandleError,
          Jido.Flow.Error,
          Jido.Flow.Error.Invalid,
          Jido.Flow.Error.ExecutionFailureError,
          Jido.Flow.Error.InternalError,
          Jido.Flow.Error.InvalidDefinitionError,
          Jido.Flow.Error.InvalidExecutionError,
          Jido.Flow.Error.TimeoutError
        ]
      ]
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "guides",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "usage-rules.md"
      ],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Documentation" => "https://hexdocs.pm/jido_action",
        "GitHub" => @source_url,
        "Website" => "https://jido.run",
        "Discord" => "https://jido.run/discord",
        "Changelog" => "https://github.com/agentjido/jido_action/blob/v#{@version}/CHANGELOG.md"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:zoi, "~> 0.17"},
      {:runic, "== 0.1.0-alpha.9"},
      {:splode, "~> 0.3.0"},
      {:spark, "~> 2.7"},

      # Development & Test Dependencies
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:doctor, "~> 0.23.0", only: :dev, runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # Helper to run tests with trace when needed
      # test: "test --trace --exclude flaky",
      test: "test --exclude flaky",

      # Run to check the quality of your code
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "doctor --summary",
        "docs --warnings-as-errors",
        "credo --min-priority high",
        "dialyzer"
      ]
    ]
  end
end
