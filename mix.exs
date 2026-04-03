defmodule Prehen.MixProject do
  use Mix.Project

  def project do
    [
      app: :prehen,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Prehen.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},

      # Phoenix
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.2"},
      {:bandit, "~> 1.0"},
      {:cors_plug, "~> 3.0"}
    ]
  end
end
