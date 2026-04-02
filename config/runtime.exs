import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :prehen, PrehenWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end

config :prehen,
  agent_profiles: [
    %{
      name: "coder",
      label: "Coder",
      implementation: "pi_coding_agent",
      default_provider: "github-copilot",
      default_model: "gpt-5.4-mini",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"}
    }
  ],
  agent_implementations: [
    %{
      name: "pi_coding_agent",
      command: System.get_env("PI_CODING_AGENT_BIN") || "pi",
      args: ["--mode", "json"],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.PiCodingAgent
    }
  ]
