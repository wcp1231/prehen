defmodule Prehen.ActionsTest do
  use ExUnit.Case

  alias Prehen.Actions.{LS, Read}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "prehen_tools_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    config = %{workspace_dir: workspace, read_max_bytes: 20}
    {:ok, workspace: workspace, config: config}
  end

  test "ls returns directory entries", %{workspace: workspace, config: config} do
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/demo.txt"), "demo")

    result = LS.invoke(%{"path" => "lib"}, config)

    assert result["ok"] == true
    assert Enum.any?(result["data"]["entries"], &(&1["name"] == "demo.txt"))
  end

  test "ls blocks path traversal", %{config: config} do
    result = LS.invoke(%{"path" => "../"}, config)

    assert result["ok"] == false
    assert result["error"]["type"] == "permission_error"
  end

  test "read returns selected lines and truncates by max_bytes", %{
    workspace: workspace,
    config: config
  } do
    file = Path.join(workspace, "notes.txt")
    File.write!(file, "line1\nline2\nline3\nline4")

    result =
      Read.invoke(
        %{"path" => "notes.txt", "start_line" => 2, "end_line" => 4, "max_bytes" => 10},
        config
      )

    assert result["ok"] == true
    assert result["data"]["start_line"] == 2
    assert result["data"]["truncated"] == true
    assert byte_size(result["data"]["content"]) == 10
  end

  test "read validates missing path", %{config: config} do
    result = Read.invoke(%{}, config)

    assert result["ok"] == false
    assert result["error"]["type"] == "validation_error"
  end

  test "local fs tools are read-only and side-effect free", %{
    workspace: workspace,
    config: config
  } do
    file = Path.join(workspace, "readonly.txt")
    File.write!(file, "alpha\nbeta")

    before_entries = File.ls!(workspace) |> Enum.sort()
    before_content = File.read!(file)

    _ = LS.invoke(%{"path" => "."}, config)
    _ = Read.invoke(%{"path" => "readonly.txt"}, config)

    after_entries = File.ls!(workspace) |> Enum.sort()
    after_content = File.read!(file)

    assert after_entries == before_entries
    assert after_content == before_content
  end

  test "tools can access .prehen metadata directory", %{workspace: workspace, config: config} do
    meta_dir = Path.join(workspace, ".prehen")
    File.mkdir_p!(meta_dir)
    File.write!(Path.join(meta_dir, "agent.txt"), "meta")

    ls_result = LS.invoke(%{"path" => ".prehen"}, config)
    read_result = Read.invoke(%{"path" => ".prehen/agent.txt"}, config)

    assert ls_result["ok"] == true
    assert Enum.any?(ls_result["data"]["entries"], &(&1["name"] == "agent.txt"))
    assert read_result["ok"] == true
    assert read_result["data"]["content"] == "meta"
  end
end
