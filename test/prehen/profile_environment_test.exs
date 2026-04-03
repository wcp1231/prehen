defmodule Prehen.ProfileEnvironmentTest do
  use ExUnit.Case, async: true

  alias Prehen.Agents.Profile
  alias Prehen.ProfileEnvironment

  test "resolves a fixed profile workspace for current profile structs" do
    root = tmp_root("profile_env_struct")
    profile_dir = Path.join([root, "profiles", "coder"])
    global_skills_dir = Path.join(root, "skills")

    File.mkdir_p!(global_skills_dir)
    File.mkdir_p!(Path.join(profile_dir, "skills"))
    File.mkdir_p!(Path.join(profile_dir, "memory"))
    File.write!(Path.join(profile_dir, "SOUL.md"), "You are Coder.\n")
    File.write!(Path.join(profile_dir, "AGENTS.md"), "Always be precise.\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, env} =
             ProfileEnvironment.load(%Profile{name: "coder"}, prehen_home: root)

    assert env.profile_dir == profile_dir
    assert env.workspace_dir == profile_dir
    assert env.global_skills_dir == global_skills_dir
    assert env.profile_skills_dir == Path.join(profile_dir, "skills")
    assert env.soul_md == "You are Coder.\n"
    assert env.agents_md == "Always be precise.\n"
  end

  test "creates fixed directories and treats SOUL.md and AGENTS.md as optional" do
    root = tmp_root("profile_env_map")
    profile_dir = Path.join([root, "profiles", "reviewer"])

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, env} =
             ProfileEnvironment.load(%{id: "reviewer", label: "Reviewer"}, prehen_home: root)

    assert env.profile_dir == profile_dir
    assert env.workspace_dir == profile_dir
    assert env.global_skills_dir == Path.join(root, "skills")
    assert env.profile_skills_dir == Path.join(profile_dir, "skills")
    assert File.dir?(env.global_skills_dir)
    assert File.dir?(env.profile_skills_dir)
    assert File.dir?(Path.join(profile_dir, "memory"))
    assert env.soul_md == ""
    assert env.agents_md == ""
  end

  defp tmp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_#{label}_#{System.unique_integer([:positive])}"
    )
  end
end
