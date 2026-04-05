defmodule ExResilience.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_resilience,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Composable resilience middleware for Elixir",
      package: package(),
      docs: docs()
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
      links: %{"GitHub" => "https://github.com/joshrotenberg/ex_resilience"}
    ]
  end

  defp docs do
    [
      main: "ExResilience",
      extras: ["CHANGELOG.md"]
    ]
  end
end
