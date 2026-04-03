defmodule Prehen.MCP.Tools.SkillsTest do
  use ExUnit.Case, async: true

  alias Prehen.MCP.Tools.Skills

  test "search sees global and selected profile skills only" do
    root = tmp_root("search")

    File.mkdir_p!(Path.join([root, "skills"]))
    File.mkdir_p!(Path.join([root, "profiles", "coder", "skills"]))
    File.mkdir_p!(Path.join([root, "profiles", "reviewer", "skills"]))

    File.write!(Path.join([root, "skills", "global.md"]), "# Global\nsummary: global skill\n")

    File.write!(
      Path.join([root, "profiles", "coder", "skills", "coder.md"]),
      "# Coder\nsummary: coder skill\n"
    )

    File.write!(
      Path.join([root, "profiles", "reviewer", "skills", "reviewer.md"]),
      "# Reviewer\nsummary: reviewer skill\n"
    )

    on_exit(fn -> File.rm_rf(root) end)

    context = %{prehen_home: root, profile_id: "coder"}

    assert {:ok, %{"skills" => skills}} = Skills.search(context, %{"query" => ""})

    ids = Enum.map(skills, & &1["id"])

    assert "global:global" in ids
    assert "profile:coder:coder" in ids
    refute "profile:reviewer:reviewer" in ids
  end

  test "load returns only visible skills" do
    root = tmp_root("load")

    File.mkdir_p!(Path.join([root, "skills"]))
    File.mkdir_p!(Path.join([root, "profiles", "coder", "skills"]))
    File.mkdir_p!(Path.join([root, "profiles", "reviewer", "skills"]))

    File.write!(Path.join([root, "skills", "global.md"]), "# Global\nsummary: global skill\n")

    File.write!(
      Path.join([root, "profiles", "coder", "skills", "coder.md"]),
      "# Coder\nsummary: coder skill\nbody\n"
    )

    File.write!(
      Path.join([root, "profiles", "reviewer", "skills", "reviewer.md"]),
      "# Reviewer\nsummary: reviewer skill\n"
    )

    on_exit(fn -> File.rm_rf(root) end)

    context = %{prehen_home: root, profile_id: "coder"}

    assert {:ok, %{"id" => "profile:coder:coder", "summary" => "coder skill", "body" => body}} =
             Skills.load(context, %{"id" => "profile:coder:coder"})

    assert body =~ "# Coder"
    assert body =~ "summary: coder skill"

    assert {:error, :not_found} = Skills.load(context, %{"id" => "profile:reviewer:reviewer"})
  end

  test "search and load skip unreadable sibling skill files" do
    root = tmp_root("unreadable")

    File.mkdir_p!(Path.join([root, "profiles", "coder", "skills"]))

    readable_path = Path.join([root, "profiles", "coder", "skills", "good.md"])
    unreadable_path = Path.join([root, "profiles", "coder", "skills", "bad.md"])

    File.write!(readable_path, "# Good\nsummary: readable skill\nbody\n")
    File.write!(unreadable_path, "# Bad\nsummary: unreadable skill\n")
    File.chmod!(unreadable_path, 0o000)

    on_exit(fn ->
      File.chmod(unreadable_path, 0o644)
      File.rm_rf(root)
    end)

    context = %{prehen_home: root, profile_id: "coder"}

    assert {:ok, %{"skills" => skills}} = Skills.search(context, %{"query" => ""})
    assert Enum.map(skills, & &1["id"]) == ["profile:coder:good"]

    assert {:ok, %{"id" => "profile:coder:good", "body" => body}} =
             Skills.load(context, %{"id" => "profile:coder:good"})

    assert body =~ "# Good"
  end

  defp tmp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_mcp_skills_#{label}_#{System.unique_integer([:positive])}"
    )
  end
end
