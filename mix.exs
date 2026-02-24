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
      {:jido, "~> 2.0.0-rc.4"},
      {:jido_action, github: "agentjido/jido_action", branch: "main", override: true, depth: 1},
      {:jido_ai, github: "agentjido/jido_ai", branch: "main", depth: 1},
      {:req_llm, github: "agentjido/req_llm", branch: "main", override: true, depth: 1},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},

      # Phoenix
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.2"},
      {:bandit, "~> 1.0"},
      {:cors_plug, "~> 3.0"}
    ]
  end
end
