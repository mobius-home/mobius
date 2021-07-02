defmodule Mobius.MixProject do
  use Mix.Project

  def project do
    [
      app: :mobius,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 0.4.3"},
      {:telemetry_metrics, "~> 0.6.0"},
      {:circular_buffer, "~> 0.4.0"}
    ]
  end
end
