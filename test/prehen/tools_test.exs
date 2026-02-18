defmodule Prehen.ActionsTest do
  use ExUnit.Case

  alias Prehen.Actions.{LS, Read}

  setup do
    root = Path.join(System.tmp_dir!(), "prehen_tools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    config = %{root_dir: root, read_max_bytes: 20}
    {:ok, root: root, config: config}
  end

  test "ls returns directory entries", %{root: root, config: config} do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.txt"), "demo")

    result = LS.invoke(%{"path" => "lib"}, config)

    assert result["ok"] == true
    assert Enum.any?(result["data"]["entries"], &(&1["name"] == "demo.txt"))
  end

  test "ls blocks path traversal", %{config: config} do
    result = LS.invoke(%{"path" => "../"}, config)

    assert result["ok"] == false
    assert result["error"]["type"] == "permission_error"
  end

  test "read returns selected lines and truncates by max_bytes", %{root: root, config: config} do
    file = Path.join(root, "notes.txt")
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
end
