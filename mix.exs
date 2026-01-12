defmodule Mobius.MixProject do
  use Mix.Project

  @version "0.6.1"

  def project do
    [
      app: :mobius,
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      description: description(),
      package: package(),
      docs: docs(),
      preferred_cli_env: [docs: :docs, "hex.publish": :docs]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.24", only: :docs, runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:telemetry, "~> 0.4.3 or ~> 1.0"},
      {:telemetry_metrics, "~> 0.6 or ~> 1.0"},
      {:circular_buffer, "~> 0.4.0"},
      {:elixir_uuid, "> 1.2.0"}
    ]
  end

  defp docs() do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: "https://github.com/mobius-home/mobius",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      assets: "assets",
      logo: "assets/m.png"
    ]
  end

  defp description do
    "Local metrics library"
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/mobius-home/mobius"}
    ]
  end

  defp dialyzer() do
    [
      flags: [:unmatched_returns, :error_handling],
      plt_add_apps: [:eex, :mix]
    ]
  end

  defp aliases() do
    [
      test: ["test --exclude timeout"]
    ]
  end
end
