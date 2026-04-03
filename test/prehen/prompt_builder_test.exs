defmodule Prehen.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Prehen.PromptBuilder

  test "builds the system prompt in fixed order with runtime context" do
    env = %{
      soul_md: "SOUL",
      agents_md: "AGENTS",
      workspace_dir: "/tmp/prehen/profiles/coder"
    }

    session = %{
      profile_name: "coder",
      provider: "github-copilot",
      model: "gpt-5.4-mini"
    }

    prompt = PromptBuilder.build(env, session, %{skills: ["skills.search", "skills.load"]})

    assert prompt =~ "PREHEN GLOBAL"
    assert prompt =~ "SOUL"
    assert prompt =~ "AGENTS"
    assert prompt =~ "profile_name: coder"
    assert prompt =~ "provider: github-copilot"
    assert prompt =~ "model: gpt-5.4-mini"
    assert prompt =~ "workspace: /tmp/prehen/profiles/coder"
    assert prompt =~ "skills.search"
    assert prompt =~ "skills.load"
    assert String.contains?(prompt, "PREHEN GLOBAL")
    assert String.contains?(prompt, "SOUL\n\nAGENTS")

    assert position(prompt, "PREHEN GLOBAL") < position(prompt, "SOUL")
    assert position(prompt, "SOUL") < position(prompt, "AGENTS")
    assert position(prompt, "AGENTS") < position(prompt, "profile_name: coder")
  end

  defp position(body, fragment) do
    {index, _length} = :binary.match(body, fragment)
    index
  end
end
