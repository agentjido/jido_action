defmodule JidoAction.MixProject do
  use Mix.Project

  @version "2.3.1"
  @source_url "https://github.com/agentjido/jido_action"
  @description "Validated leaf actions and action call frames for Elixir applications"

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
        "Start Here": [
          "guides/getting-started.md",
          "guides/your-second-action.md"
        ],
        "Core Execution": [
          "guides/actions-guide.md",
          "guides/instructions.md",
          "guides/exec.md",
          "guides/schemas-validation.md",
          "guides/error-handling.md"
        ],
        "Jido Flow": [
          "guides/jido-flow.md",
          "guides/flow-authoring-languages.md"
        ],
        "Production Use": [
          "guides/configuration.md",
          "guides/security.md",
          "guides/testing.md"
        ],
        Reference: [
          "guides/faq.md",
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      extras: [
        # Home & Project
        {"README.md", title: "Home"},
        # Start Here
        {"guides/getting-started.md", title: "Getting Started"},
        {"guides/your-second-action.md", title: "Your Second Action"},
        # Core Execution
        {"guides/actions-guide.md", title: "Jido.Action"},
        {"guides/instructions.md", title: "Jido.Instruction"},
        {"guides/exec.md", title: "Jido.Exec"},
        {"guides/schemas-validation.md", title: "Schemas & Validation"},
        {"guides/error-handling.md", title: "Error Handling"},
        # Jido Flow
        {"guides/jido-flow.md", title: "How Jido Flow Works"},
        {"guides/flow-authoring-languages.md", title: "Flow Authoring Languages"},
        # Production Use
        {"guides/configuration.md", title: "Configuration"},
        {"guides/security.md", title: "Security"},
        {"guides/testing.md", title: "Testing"},
        # Reference
        {"guides/faq.md", title: "FAQ"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "Apache 2.0 License"}
      ],
      extra_section: "Guides",
      formatters: ["html"],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Core Execution": [
          Jido.Action,
          Jido.Action.Output,
          Jido.Exec,
          Jido.Instruction
        ],
        Flow: [
          Jido.Flow,
          Jido.Flow.Builder,
          Jido.Flow.Compiler,
          Jido.Flow.Node,
          Jido.Flow.Parser,
          Jido.Flow.Ref,
          Jido.Flow.Syntax,
          Jido.Flow.Syntax.Lowerer
        ],
        "Error Types": [
          Jido.Action.Error,
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
