defmodule Aurinko.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/iamkanishka/aurinko.ex"
  @description """
  Production-grade Elixir client for the Aurinko Unified Mailbox API.
  Covers Email, Calendar, Contacts, Tasks, Webhooks, and Booking with
  caching, rate-limiting, circuit breaking, streaming pagination, and telemetry.
  """

  def project do
    [
      app: :aurinko,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description,
      package: package(),
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ],
      dialyzer: dialyzer(),
      name: "Aurinko",
      source_url: @source_url,
      homepage_url: "https://aurinko.io"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Aurinko.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:faker, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      name: "aurinko",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Aurinko Docs" => "https://docs.aurinko.io",
        "Getting Started" => "#{@source_url}/blob/master/guides/getting_started.md",
        "Advanced Guide" => "#{@source_url}/blob/master/guides/advanced.md",
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      maintainers: ["Kanishka Naik"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md guides)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "guides/getting_started.md"],
      groups_for_modules: [
        Core: [Aurinko, Aurinko.Config],
        Authentication: [Aurinko.Auth],
        APIs: [
          Aurinko.API.Email,
          Aurinko.API.Calendar,
          Aurinko.API.Contacts,
          Aurinko.API.Tasks,
          Aurinko.API.Webhooks,
          Aurinko.API.Booking
        ],
        "Sync & Streaming": [Aurinko.Sync.Orchestrator, Aurinko.Paginator],
        "Cache & Rate Limiting": [
          Aurinko.Cache,
          Aurinko.RateLimiter,
          Aurinko.CircuitBreaker
        ],
        Observability: [Aurinko.Telemetry],
        Errors: [Aurinko.Error]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.compile"],
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      "test.all": ["coveralls.html"],
      quality: ["lint", "test.all"]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/project.plt"},
      plt_add_apps: [:ex_unit, :mix],
      flags: [:error_handling, :missing_return, :underspecs],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
