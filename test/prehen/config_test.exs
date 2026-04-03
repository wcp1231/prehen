defmodule Prehen.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig
  alias Prehen.Config

  setup do
    original_home = System.get_env("PREHEN_HOME")

    on_exit(fn ->
      case original_home do
        nil -> System.delete_env("PREHEN_HOME")
        value -> System.put_env("PREHEN_HOME", value)
      end
    end)

    :ok
  end

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

  test "drops invalid profile structs that do not satisfy phase 1 requirements" do
    config =
      Config.load(
        agent_profiles: [
          %Profile{
            name: "broken",
            implementation: "pi_coding_agent"
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
      )

    assert config.agent_profiles == []
    assert_raise KeyError, fn -> Config.resolve_session_config!(config, agent: "broken") end
  end

  test "bridges enabled user config profiles into internal phase 1 agent profiles" do
    log =
      capture_log(fn ->
        config =
          Config.load(
            user_config: %{
              profiles: [
                %{
                  id: "coder",
                  label: "Coder",
                  description: "Writes code",
                  runtime: "pi",
                  default_provider: "github-copilot",
                  default_model: "gpt-5.4-mini",
                  enabled: true
                },
                %{
                  id: "disabled",
                  label: "Disabled",
                  description: "Ignored",
                  runtime: "pi",
                  default_provider: "github-copilot",
                  default_model: "gpt-5.4-mini",
                  enabled: false
                },
                %{
                  id: "unsupported",
                  label: "Unsupported",
                  runtime: "other",
                  default_provider: "github-copilot",
                  default_model: "gpt-5.4-mini",
                  enabled: true
                }
              ],
              providers: %{},
              channels: %{}
            },
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

        send(self(), {:config, config})
      end)

    assert_received {:config, config}

    assert [
             %Profile{
               name: "coder",
               label: "Coder",
               description: "Writes code",
               implementation: "pi_coding_agent",
               default_provider: "github-copilot",
               default_model: "gpt-5.4-mini",
               prompt_profile: "coder_default",
               workspace_policy: %{mode: "scoped"}
             }
           ] = config.agent_profiles

    assert %SessionConfig{
             profile_name: "coder",
             provider: "github-copilot",
             model: "gpt-5.4-mini",
             prompt_profile: "coder_default",
             workspace_policy: %{mode: "scoped"}
           } = Config.resolve_session_config!(config, agent: "coder")

    assert log =~ "Dropped user profile"
    assert log =~ "unsupported runtime"
    refute log =~ ~s(Dropped user profile "disabled")
  end

  test "falls back to empty user config when config.yaml cannot be loaded" do
    root =
      Path.join(System.tmp_dir!(), "prehen_config_missing_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    System.put_env("PREHEN_HOME", root)

    config =
      Config.load(
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

    assert config.agent_profiles == []
    assert [%Implementation{name: "pi_coding_agent"}] = config.agent_implementations
  end

  test "does not read user config from disk when agent_profiles override is provided" do
    root =
      Path.join(
        System.tmp_dir!(),
        "prehen_skip_user_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    File.write!(Path.join(root, "config.yaml"), """
    profiles:
      - id: coder
        label: [not valid yaml
    """)

    log =
      capture_log(fn ->
        config =
          Config.load(
            prehen_home: root,
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

        send(self(), {:explicit_profiles_config, config})
      end)

    assert_received {:explicit_profiles_config, config}
    assert [%Profile{name: "coder"}] = config.agent_profiles
    refute log =~ "Failed to load Prehen user config"
  end

  test "warns and falls back when malformed user config is loaded from prehen_home" do
    root =
      Path.join(
        System.tmp_dir!(),
        "prehen_malformed_user_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    File.write!(Path.join(root, "config.yaml"), """
    profiles:
      - id: coder
        label: [not valid yaml
    """)

    log =
      capture_log(fn ->
        config =
          Config.load(
            prehen_home: root,
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

        send(self(), {:malformed_config, config})
      end)

    assert_received {:malformed_config, config}
    assert config.agent_profiles == []
    assert [%Implementation{name: "pi_coding_agent"}] = config.agent_implementations
    assert log =~ "Failed to load Prehen user config"
  end
end
