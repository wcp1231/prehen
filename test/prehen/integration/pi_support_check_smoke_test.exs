defmodule Prehen.Integration.PiSupportCheckSmokeTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrappers.PiCodingAgent
  alias Prehen.Config

  @enable_env "PREHEN_REAL_PI_SUPPORT_CHECK"
  @enabled? System.get_env(@enable_env) in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]

  @moduletag timeout: 30_000
  @moduletag skip:
               if(
                 @enabled?,
                 do: false,
                 else:
                   "set #{@enable_env}=1 to run the real pi support_check smoke against local credentials"
               )

  test "runtime-configured pi profile passes support_check" do
    config = Config.load()
    profile = List.first(Map.get(config, :agent_profiles, [])) || flunk("expected one profile")

    implementation =
      Enum.find(Map.get(config, :agent_implementations, []), fn implementation ->
        implementation.name == profile.implementation
      end) || flunk("expected implementation #{inspect(profile.implementation)}")

    workspace = tmp_workspace_path("real_pi_support_check")

    session_config = %SessionConfig{
      profile_name: profile.name,
      provider: profile.default_provider,
      model: profile.default_model,
      prompt_profile: profile.prompt_profile,
      workspace_policy: profile.workspace_policy,
      implementation: implementation,
      workspace: workspace
    }

    assert :ok = PiCodingAgent.support_check(session_config)
  end

  defp tmp_workspace_path(label) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_real_pi_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    workspace
  end
end
