defmodule JidoAction.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/agentjido/jido_action"
  @description "Composable, validated actions for Elixir applications with built-in AI tool integration"

  def vsn do
    @version
  end

  def project do
    [
      app: :jido_action,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "Jido Action",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Coverage
      test_coverage: [
        tool: ExCoveralls,
        # summary: [threshold: 80],
        # export: "cov",
        ignore_modules: [~r/^JidoTest\.TestActions\./]
      ],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.lcov": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
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
          "guides/getting-started.livemd"
        ],
        "About JidoAction": [
          "guides/about/what-is-jido-action.md",
          "guides/about/design-principles.md",
          "guides/about/alternatives.md",
          "CONTRIBUTING.md",
          "CHANGELOG.md",
          "LICENSE.md"
        ],
        Examples: [
          "guides/examples/your-first-action.livemd",
          "guides/examples/tool-use.livemd",
          "guides/examples/chain-of-thought.livemd",
          "guides/examples/think-plan-act.livemd",
          "guides/examples/multi-agent.livemd"
        ],
        Actions: [
          "guides/actions/overview.md",
          "guides/actions/workflows.md",
          "guides/actions/instructions.md",
          "guides/actions/directives.md",
          "guides/actions/runners.md",
          "guides/actions/actions-as-tools.md",
          "guides/actions/testing.md"
        ]
      ],
      extras: [
        # Home & Project
        {"README.md", title: "Home"},
        # Getting Started Section
        {"guides/getting-started.livemd", title: "Quick Start"},
        # About JidoAction
        {"guides/about/what-is-jido-action.md", title: "What is JidoAction?"},
        {"guides/about/design-principles.md", title: "Design Principles"},
        {"guides/about/alternatives.md", title: "Alternatives"},
        {"CONTRIBUTING.md", title: "Contributing"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE.md", title: "Apache 2.0 License"},
        # Examples
        {"guides/examples/hello-world.livemd", title: "Hello World"},
        {"guides/examples/tool-use.livemd", title: "Actions with Tools"},
        {"guides/examples/think-plan-act.livemd", title: "Think-Plan-Act"},
        {"guides/examples/chain-of-thought.livemd", title: "Chain of Thought"},
        {"guides/examples/multi-agent.livemd", title: "Multi-Agent Systems"},
        # Actions
        {"guides/actions/overview.md", title: "Overview"},
        {"guides/actions/workflows.md", title: "Executing Actions"},
        {"guides/actions/instructions.md", title: "Instructions"},
        {"guides/actions/directives.md", title: "Directives"},
        {"guides/actions/runners.md", title: "Runners"},
        {"guides/actions/actions-as-tools.md", title: "Actions as LLM Tools"},
        {"guides/actions/testing.md", title: "Testing"},
        # Skills
        {"guides/skills/overview.md", title: "Overview"},
        {"guides/skills/testing.md", title: "Testing Skills"}
      ],
      extra_section: "Guides",
      formatters: ["html"],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      groups_for_modules: [
        Core: [
          Jido.Action,
          Jido.Action.Error,
          Jido.Action.Exec,
          Jido.Action.Tool,
          Jido.Action.Util
        ],
        "Actions: Execution": [
          Jido.Action.Exec.Chain,
          Jido.Action.Exec.Closure
        ],
        "Actions: Tools": [
          Jido.Tools.Arithmetic,
          Jido.Tools.Basic,
          Jido.Tools.Files,
          Jido.Tools.Req,
          Jido.Tools.Simplebot,
          Jido.Tools.Weather,
          Jido.Tools.Workflow
        ],
        "Actions: GitHub": [
          Jido.Tools.Github.Issues
        ],
        Utilities: [
          Jido.Instruction
        ]
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "AgentJido.xyz" => "https://agentjido.xyz",
        "Jido Workbench" => "https://github.com/agentjido/jido_workbench"
      }
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_dbug, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:ok, "~> 2.3"},
      {:private, "~> 0.1.2"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:typed_struct, "~> 0.3.0"},
      {:uniq, "~> 0.6.1"},

      # Skill & Action Dependencies for examples
      {:abacus, "~> 2.1"},
      # {:libgraph, "~> 0.16.0"},
      {:libgraph, "~> 0.16.0",
       [
         env: :prod,
         git: "https://github.com/zblanco/libgraph.git",
         branch: "zw/multigraph-indexes"
       ]},
      {:req, "~> 0.5.10"},
      {:runic, github: "zblanco/runic", branch: "zw/map"},
      {:tentacat, "~> 2.5"},
      {:weather, "~> 0.4.0"},

      # Development & Test Dependencies
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18.3", only: [:dev, :test]},
      {:expublish, "~> 2.7", only: [:dev], runtime: false},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.11", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      # Helper to run tests with trace when needed
      # test: "test --trace --exclude flaky",
      test: "test --exclude flaky",
      # Helper to run docs
      # docs: "docs -f html --open",
      # Run to check the quality of your code
      q: ["quality"],
      quality: [
        "format",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "dialyzer --format dialyxir",
        "credo --all"
      ]
    ]
  end
end
