defmodule Prehen.Agents.PromptContextTest do
  use ExUnit.Case, async: true

  alias Prehen.Agents.PromptContext
  alias Prehen.Agents.SessionConfig

  test "builds prompt context from session config workspace and capabilities" do
    session_config = %SessionConfig{
      profile_name: "coder",
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"}
    }

    assert %{
             prompt_profile: "coder_default",
             session: %{
               profile_name: "coder",
               provider: "openai",
               model: "gpt-5"
             },
             workspace: %{
               root_dir: "/tmp/project",
               policy: %{mode: "scoped"}
             },
             capabilities: %{
               fs_patch: true
             }
           } =
             PromptContext.build(
               session_config,
               workspace: %{root_dir: "/tmp/project"},
               capabilities: %{fs_patch: true}
             )
  end

  test "omits capabilities when none are provided" do
    session_config = %SessionConfig{
      profile_name: "coder",
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"}
    }

    context = PromptContext.build(session_config, workspace: %{root_dir: "/tmp/project"})

    assert context.workspace == %{root_dir: "/tmp/project", policy: %{mode: "scoped"}}
    refute Map.has_key?(context, :capabilities)
  end
end
