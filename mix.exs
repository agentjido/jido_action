defmodule JidoAction.MixProject do
  use Mix.Project

  @version "2.3.1"
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
        ignore_modules: [
          ~r/^Inspect\.JidoTest\./,
          ~r/^JidoTest\./,
          ~r/^Mix\.Tasks\./,
          Jido.Action.Error.Config,
          Jido.Action.Error.Execution,
          Jido.Action.Error.Internal,
          Jido.Action.Error.Invalid
        ],
        summary: [threshold: 0]
      ],

      # Dialyzer
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix, :igniter]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Jido.Action.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/jido/bus/support"]
  defp elixirc_paths(:dev), do: ["lib", "bench"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      api_reference: false,
      source_ref: "v#{@version}",
      source_url: "https://github.com/agentjido/jido_action",
      authors: ["Mike Hostetler <mike.hostetler@gmail.com>"],
      groups_for_extras: [
        Project: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        "Getting Started": [
          "guides/getting-started.livemd"
        ],
        "Core Concepts": [
          "guides/actions.md",
          "guides/instructions.md",
          "guides/flows.md",
          "guides/execution.md",
          "guides/schemas-validation.md"
        ],
        "Building Flows": [
          "guides/build-your-first-flow.livemd",
          "guides/flow-language.livemd",
          "guides/flow-steps.livemd",
          "guides/flow-references.livemd",
          "guides/flow-dependencies.livemd",
          "guides/flow-collections.livemd",
          "guides/flow-choices.livemd",
          "guides/flow-loops-state.livemd",
          "guides/nested-flows.livemd",
          "guides/flow-modules.md",
          "guides/flow-storage.md",
          "guides/flow-builder.md",
          "guides/flow-inspection.md"
        ],
        Operations: [
          "guides/flow-execution.livemd",
          "guides/configuration.md",
          "guides/security.md",
          "guides/testing.md"
        ]
      ],
      extras: [
        # Project
        {"README.md", title: "Home"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "Apache 2.0 License"},
        # Getting Started
        {"guides/getting-started.livemd", title: "Getting Started"},
        # Core Concepts
        {"guides/actions.md", title: "Actions"},
        {"guides/instructions.md", title: "Instructions"},
        {"guides/flows.md", title: "Flows"},
        {"guides/execution.md", title: "Execution"},
        {"guides/schemas-validation.md", title: "Schemas & Validation"},
        # Building Flows
        {"guides/build-your-first-flow.livemd", title: "Build Your First Flow"},
        {"guides/flow-language.livemd", title: "Flow Language Overview"},
        {"guides/flow-steps.livemd", title: "Steps & Outputs"},
        {"guides/flow-references.livemd", title: "References & Data Mapping"},
        {"guides/flow-dependencies.livemd", title: "Dependencies & Parallel Work"},
        {"guides/flow-collections.livemd", title: "Map & Reduce"},
        {"guides/flow-choices.livemd", title: "Choices & Conditions"},
        {"guides/flow-loops-state.livemd", title: "Iterate & State"},
        {"guides/nested-flows.livemd", title: "Nested Flows"},
        {"guides/flow-modules.md", title: "Flow Modules"},
        {"guides/flow-storage.md", title: "Stored Flow JSON"},
        {"guides/flow-builder.md", title: "Runtime Builder"},
        {"guides/flow-inspection.md", title: "Inspecting & Storing Flows"},
        # Operations
        {"guides/flow-execution.livemd", title: "Executing Flows"},
        {"guides/configuration.md", title: "Configuration"},
        {"guides/security.md", title: "Security"},
        {"guides/testing.md", title: "Testing"}
      ],
      extra_section: "Guides",
      formatters: ["html"],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "LICENSE",
        "lib/jido_flow/builder.ex",
        "lib/jido_flow/syntax.ex"
      ],
      groups_for_modules: [
        Core: [
          Jido.Action,
          Jido.Action.Error,
          Jido.Instruction
        ],
        "Flow & Execution": [
          Jido.Flow,
          Jido.Flow.Builder,
          Jido.Flow.Choice,
          Jido.Flow.Condition,
          Jido.Flow.Loop,
          Jido.Flow.Map,
          Jido.Flow.Node,
          Jido.Flow.Reduce,
          Jido.Flow.Ref,
          Jido.Flow.State,
          Jido.Flow.Syntax,
          Jido.Exec,
          Jido.Exec.Execution,
          Jido.Exec.NodeResult
        ],
        "Error Types": [
          Jido.Action.Error.Config,
          Jido.Action.Error.ConfigurationError,
          Jido.Action.Error.Execution,
          Jido.Action.Error.ExecutionFailureError,
          Jido.Action.Error.Internal,
          Jido.Action.Error.Internal.UnknownError,
          Jido.Action.Error.InternalError,
          Jido.Action.Error.Invalid,
          Jido.Action.Error.InvalidInputError,
          Jido.Action.Error.TimeoutError
        ]
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE", "usage-rules.md"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Documentation" => "https://hexdocs.pm/jido_action",
        "GitHub" => @source_url,
        "Website" => "https://jido.run",
        "Discord" => "https://jido.run/discord",
        "Changelog" => "https://github.com/agentjido/jido_action/blob/main/CHANGELOG.md"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:zoi, "~> 0.17"},
      {:runic, "~> 0.1.0-alpha.8"},
      {:splode, "~> 0.3.0"},
      {:spark, "~> 2.7"},

      # Development & Test Dependencies
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.0", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},

      # Code generation
      {:igniter, "~> 0.7", only: [:dev, :test], runtime: false, optional: true}
    ]
  end

  defp aliases do
    [
      # Helper to run tests with trace when needed
      # test: "test --trace --exclude flaky",
      test: "test --exclude flaky",

      # Helper to run docs
      docs: "docs -f html --open",

      # Run to check the quality of your code
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer"
      ]
    ]
  end
end
