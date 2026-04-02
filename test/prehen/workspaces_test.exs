defmodule Prehen.WorkspacesTest do
  use ExUnit.Case, async: true

  alias Prehen.Workspaces

  test "resolve allocates an absolute workspace when none is provided" do
    assert {:ok, workspace} = Workspaces.resolve(nil, "coder")
    assert is_binary(workspace)
    assert Path.type(workspace) == :absolute
    assert File.dir?(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)
  end

  test "resolve preserves an explicit workspace path" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "prehen_workspace_explicit_#{System.unique_integer([:positive])}"
      )

    assert {:ok, ^workspace} = Workspaces.resolve(workspace, "coder")
    assert File.dir?(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)
  end
end
