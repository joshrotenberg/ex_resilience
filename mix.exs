defmodule ExResilience.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/joshrotenberg/ex_resilience"

  def project do
    [
      app: :ex_resilience,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Composable resilience middleware for Elixir",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_file: {:no_warn, "_build/dev/dialyxir_#{System.otp_release()}.plt"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "ExResilience",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [],
      groups_for_modules: [
        "Core Patterns": [
          ExResilience.Bulkhead,
          ExResilience.CircuitBreaker,
          ExResilience.Retry,
          ExResilience.RateLimiter
        ],
        "Extended Patterns": [
          ExResilience.Coalesce,
          ExResilience.Hedge,
          ExResilience.Chaos,
          ExResilience.Fallback,
          ExResilience.Cache
        ],
        Cache: [
          ExResilience.Cache.Backend,
          ExResilience.Cache.EtsBackend
        ],
        Infrastructure: [
          ExResilience.Pipeline,
          ExResilience.Backoff,
          ExResilience.Telemetry
        ]
      ]
    ]
  end
end
