defmodule JidoAction.MixProject do
  use Mix.Project

  @version "3.0.0-beta.12"
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
      propcheck: [
        counter_examples:
          Path.join(System.get_env("MIX_BUILD_PATH", "_build"), "propcheck-property.ctx")
      ],
      test_ignore_filters: [
        # This consumer compiles only in the isolated build tests.
        &String.starts_with?(&1, "test/fixtures/inline_consumer/"),
        # test_helper.exs loads these intentionally incomplete Actions.
        &(&1 == "test/support/fixtures/action/missing_callbacks.exs"),
        # Authoring source is compiled only by the selected authoring suite.
        &String.starts_with?(&1, "test/authoring/support/"),
        # Property support is loaded explicitly by its owning test file.
        fn path ->
          String.starts_with?(path, "test/property/") and
            String.contains?(path, "/support/")
        end,
        fn path ->
          String.starts_with?(path, "test/bench/") and
            not String.ends_with?(path, "_test.exs")
        end,
        fn path ->
          String.starts_with?(path, "test/load/") and
            not String.ends_with?(path, "_test.exs")
        end
      ],

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
      mod: {Jido.Action.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.authoring": :test,
        "test.system": :test,
        "test.load": :test,
        "test.property": :test,
        "test.fuzz": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      api_reference: true,
      source_ref: "v#{@version}",
      source_url: "https://github.com/agentjido/jido_action",
      authors: ["Mike Hostetler <mike.hostetler@gmail.com>"],
      groups_for_extras: [
        "Start Here": [
          "README.md",
          "guides/getting-started.livemd",
          "guides/concepts.md",
          "guides/build-your-first-flow.livemd"
        ],
        Actions: [
          "guides/actions.md",
          "guides/schemas-validation.md",
          "guides/action-effects.livemd",
          "guides/instructions.md"
        ],
        "Author Flows": [
          "guides/flows.md",
          "guides/flow-language.livemd",
          "guides/flow-steps.livemd",
          "guides/inline-actions.md",
          "guides/flow-references.livemd",
          "guides/flow-expressions.md",
          "guides/flow-dependencies.livemd",
          "guides/flow-choices.livemd",
          "guides/flow-collections.livemd",
          "guides/flow-iterate-state.livemd",
          "guides/nested-flows.livemd",
          "guides/dynamic-flows.md",
          "guides/flow-modules.md"
        ],
        "Flows As Data": [
          "guides/flow-data.md",
          "guides/flow-storage.md",
          "guides/flow-inspection.md"
        ],
        "Run And Operate": [
          "guides/execution.md",
          "guides/flow-execution.livemd",
          "guides/managed-execution.md",
          "guides/errors.md",
          "guides/debugging-flows.md",
          "guides/testing.md",
          "guides/security.md"
        ],
        Extend: [
          "guides/building-dsls-with-inline-actions.md"
        ],
        Reference: [
          "guides/public-contracts.md",
          "guides/benchmarks.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        Upgrade: [
          "guides/v2-to-v3-migration.md",
          "guides/v2-to-v3-upgrade-skill.md"
        ],
        "Visual Test": [
          "guides/visual-test.md"
        ]
      ],
      extras: [
        # Start Here
        {"README.md", title: "Home"},
        {"guides/getting-started.livemd", title: "Getting Started"},
        {"guides/concepts.md", title: "Core Concepts"},
        {"guides/build-your-first-flow.livemd", title: "Build Your First Flow"},
        # Actions
        {"guides/actions.md", title: "Actions"},
        {"guides/schemas-validation.md", title: "Schemas And Validation"},
        {"guides/action-effects.livemd", title: "Outputs And Effects"},
        {"guides/instructions.md", title: "Instructions"},
        # Author Flows
        {"guides/flows.md", title: "Flows"},
        {"guides/flow-language.livemd", title: "Flow DSL Tour"},
        {"guides/flow-steps.livemd", title: "Steps And Output"},
        {"guides/inline-actions.md", title: "Inline Steps"},
        {"guides/flow-references.livemd", title: "References And Data"},
        {"guides/flow-expressions.md", title: "Expressions"},
        {"guides/flow-dependencies.livemd", title: "Dependencies And Parallel Work"},
        {"guides/flow-choices.livemd", title: "Choices And Conditions"},
        {"guides/flow-collections.livemd", title: "Map And Reduce"},
        {"guides/flow-iterate-state.livemd", title: "Iterate And State"},
        {"guides/nested-flows.livemd", title: "Nested Flows"},
        {"guides/dynamic-flows.md", title: "Dynamic Flows With Dispatch"},
        {"guides/flow-modules.md", title: "Flow Modules And Extensions"},
        # Flows As Data
        {"guides/flow-data.md", title: "Flow Data Definitions"},
        {"guides/flow-storage.md", title: "Store Flows As JSON"},
        {"guides/flow-inspection.md", title: "Inspect Flows"},
        # Run And Operate
        {"guides/execution.md", title: "Execution"},
        {"guides/flow-execution.livemd", title: "Executing Flows"},
        {"guides/managed-execution.md", title: "Managed Execution"},
        {"guides/errors.md", title: "Errors"},
        {"guides/debugging-flows.md", title: "Debug Flows"},
        {"guides/testing.md", title: "Testing"},
        {"guides/security.md", title: "Security"},
        # Extend
        {"guides/building-dsls-with-inline-actions.md",
         title: "Building DSLs With Inline Actions"},
        # Reference
        {"guides/public-contracts.md", title: "Public Contract Register"},
        {"guides/benchmarks.md", title: "Execution Benchmarks"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "Apache 2.0 License"},
        # Upgrade
        {"guides/v2-to-v3-migration.md", title: "Version 2 To Version 3 Migration Guide"},
        {"guides/v2-to-v3-upgrade-skill.md", title: "v2 To v3 Upgrade Skill"},
        # Visual Test
        {"guides/visual-test.md", title: "Visual Test: Flow Diagrams"}
      ],
      assets: %{"guides/assets" => "assets"},
      extra_section: "Guides",
      formatters: ["html"],
      # The migration guide names removed functions on purpose.
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "LICENSE",
        "guides/v2-to-v3-migration.md"
      ],
      groups_for_modules: [
        Actions: [
          Jido.Action,
          Jido.Action.Output,
          Jido.Action.Inline
        ],
        Instructions: [Jido.Instruction],
        Flows: [
          Jido.Flow,
          Jido.Flow.Ref,
          Jido.Flow.Value,
          Jido.Flow.Extension
        ],
        "Flow Storage": [
          Jido.Flow.Codec,
          Jido.Flow.Registry
        ],
        Expressions: [Jido.Expr, Jido.Expr.Error],
        Execution: [Jido.Exec, Jido.Exec.Telemetry],
        "Action Errors": [
          Jido.Action.Error,
          Jido.Action.Error.InvalidInputError,
          Jido.Action.Error.ExecutionFailureError,
          Jido.Action.Error.TimeoutError,
          Jido.Action.Error.ConfigurationError,
          Jido.Action.Error.InternalError
        ],
        "Flow Errors": [
          Jido.Flow.Error,
          Jido.Flow.Error.Invalid,
          Jido.Flow.Error.InvalidDefinitionError,
          Jido.Flow.Error.InvalidExecutionError,
          Jido.Flow.Error.ExecutionFailureError,
          Jido.Flow.Error.TimeoutError,
          Jido.Flow.Error.InternalError
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
      {:zoi, "~> 0.18.11"},
      {:jason, "~> 1.4"},
      {:runic, github: "mikehostetler/runic", branch: "integration/jido-v3", override: true},
      {:splode, "~> 0.3.0"},
      {:spark, "~> 2.7.3"},

      # Development & Test Dependencies
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:doctor, "~> 0.23.0", only: :dev, runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: :test, runtime: false},
      {:propcheck, "~> 1.5", only: :test, runtime: false}
    ]
  end

  defp aliases do
    [
      # Helper to run tests with trace when needed
      # test: "test --trace --exclude flaky",
      test: "test --exclude flaky",
      "test.authoring": "test test/authoring --only authoring --seed 0",
      "test.system": "test test/system --only system --seed 0",
      "test.load": "test test/load --only load --seed 0",
      "test.property": "test test/property --only property --seed 0",
      "test.fuzz": "test test/property --only fuzz --seed 0",

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
