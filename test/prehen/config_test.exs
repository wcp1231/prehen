defmodule Prehen.ConfigTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig
  alias Prehen.Config

  test "normalizes profiles implementations and session defaults" do
    config =
      Config.load(
        agent_profiles: [
          %{
            name: "coder",
            label: "Coder",
            implementation: "pi_coding_agent",
            default_provider: "openai",
            default_model: "gpt-5",
            prompt_profile: "coder_default",
            workspace_policy: %{mode: "scoped"}
          }
        ],
        agent_implementations: [
          %{
            name: "pi_coding_agent",
            command: "pi-coding-agent",
            args: ["serve"],
            env: %{},
            wrapper: Prehen.Agents.Wrappers.PiCodingAgent
          }
        ]
      )

    assert [%Profile{name: "coder", implementation: "pi_coding_agent"}] = config.agent_profiles

    assert [
             %Implementation{
               name: "pi_coding_agent",
               wrapper: Prehen.Agents.Wrappers.PiCodingAgent
             }
           ] = config.agent_implementations

    assert %SessionConfig{
             profile_name: "coder",
             provider: "openai",
             model: "gpt-5",
             prompt_profile: "coder_default"
           } = Config.resolve_session_config!(config, agent: "coder")
  end
end
