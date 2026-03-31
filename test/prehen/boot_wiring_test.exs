defmodule Prehen.BootWiringTest do
  use ExUnit.Case, async: true

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile

  test "application passes profiles and implementations from the same loaded config" do
    config = %{
      agent_profiles: [
        %Profile{
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
        %Implementation{
          name: "pi_coding_agent",
          command: "pi-coding-agent",
          args: ["serve"],
          env: %{},
          wrapper: Prehen.Agents.Wrappers.PiCodingAgent
        }
      ]
    }

    assert [
             agent_profiles: [%Profile{name: "coder"}],
             agent_implementations: [%Implementation{name: "pi_coding_agent"}]
           ] = Prehen.Application.gateway_opts(config)
  end

  test "gateway supervisor forwards both profiles and implementations into registry startup" do
    profile = %Profile{
      name: "coder",
      label: "Coder",
      implementation: "pi_coding_agent",
      default_provider: "openai",
      default_model: "gpt-5",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"}
    }

    implementation = %Implementation{
      name: "pi_coding_agent",
      command: "pi-coding-agent",
      args: ["serve"],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.PiCodingAgent
    }

    assert [profiles: [^profile], implementations: [^implementation]] =
             Prehen.Gateway.Supervisor.registry_opts(
               agent_profiles: [profile],
               agent_implementations: [implementation]
             )
  end
end
