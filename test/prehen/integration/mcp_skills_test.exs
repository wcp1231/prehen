defmodule Prehen.Integration.MCPSkillsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Prehen.MCP.SessionAuth

  @endpoint PrehenWeb.Endpoint

  setup do
    prehen_home = tmp_prehen_home("mcp_skills")
    previous_prehen_home = System.get_env("PREHEN_HOME")

    File.mkdir_p!(Path.join([prehen_home, "skills"]))
    File.mkdir_p!(Path.join([prehen_home, "profiles", "coder", "skills"]))
    File.mkdir_p!(Path.join([prehen_home, "profiles", "reviewer", "skills"]))

    File.write!(
      Path.join([prehen_home, "skills", "global.md"]),
      "# Global\nsummary: global skill\nAlways check the global rule.\n"
    )

    File.write!(
      Path.join([prehen_home, "profiles", "coder", "skills", "coder.md"]),
      "# Coder\nsummary: coder skill\nCoder body.\n"
    )

    File.write!(
      Path.join([prehen_home, "profiles", "reviewer", "skills", "reviewer.md"]),
      "# Reviewer\nsummary: reviewer skill\nReviewer body.\n"
    )

    System.put_env("PREHEN_HOME", prehen_home)

    on_exit(fn ->
      restore_prehen_home(previous_prehen_home)
      File.rm_rf(prehen_home)
    end)

    {:ok, prehen_home: prehen_home}
  end

  test "POST /mcp lists and calls skill tools for an authorized session" do
    assert {:ok, token} = SessionAuth.issue("gw_1", "coder")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "list-1",
        "method" => "tools/list",
        "params" => %{}
      })

    assert %{"jsonrpc" => "2.0", "id" => "list-1", "result" => %{"tools" => tools}} =
             json_response(conn, 200)

    assert Enum.any?(tools, &(&1["name"] == "skills.search"))
    assert Enum.any?(tools, &(&1["name"] == "skills.load"))

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "search-1",
        "method" => "tools/call",
        "params" => %{
          "name" => "skills.search",
          "arguments" => %{"query" => "skill"}
        }
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "search-1",
             "result" => %{"skills" => skills}
           } = json_response(conn, 200)

    ids = Enum.map(skills, & &1["id"])
    assert "global:global" in ids
    assert "profile:coder:coder" in ids
    refute "profile:reviewer:reviewer" in ids

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "load-1",
        "method" => "tools/call",
        "params" => %{
          "name" => "skills.load",
          "arguments" => %{"id" => "profile:coder:coder"}
        }
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "load-1",
             "result" => %{"id" => "profile:coder:coder", "body" => body}
           } = json_response(conn, 200)

    assert body =~ "Coder body."
  end

  test "POST /mcp returns a JSON-RPC unauthorized error without a valid bearer token" do
    conn =
      post(build_conn(), "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "unauthorized-1",
        "method" => "tools/list",
        "params" => %{}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "unauthorized-1",
             "error" => %{"code" => -32001, "message" => "unauthorized"}
           } = json_response(conn, 401)
  end

  test "POST /mcp keeps tools scoped to the session capability set" do
    assert {:ok, token} = SessionAuth.issue("gw_2", "coder", capabilities: ["skills.search"])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "restricted-list-1",
        "method" => "tools/list",
        "params" => %{}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "restricted-list-1",
             "result" => %{"tools" => [%{"name" => "skills.search"}]}
           } = json_response(conn, 200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "restricted-load-1",
        "method" => "tools/call",
        "params" => %{
          "name" => "skills.load",
          "arguments" => %{"id" => "profile:coder:coder"}
        }
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "restricted-load-1",
             "error" => %{"code" => -32601, "message" => "method_not_found"}
           } = json_response(conn, 200)
  end

  test "POST /mcp rejects non-local requests even with a valid bearer token" do
    assert {:ok, token} = SessionAuth.issue("gw_3", "coder")

    conn =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "remote-1",
        "method" => "tools/list",
        "params" => %{}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "remote-1",
             "error" => %{"code" => -32003, "message" => "local_only"}
           } = json_response(conn, 403)
  end

  test "POST /mcp returns method_not_found for an unknown JSON-RPC method" do
    assert {:ok, token} = SessionAuth.issue("gw_1", "coder")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => "unknown-1",
        "method" => "unknown/method",
        "params" => %{}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "unknown-1",
             "error" => %{"code" => -32601, "message" => "method_not_found"}
           } = json_response(conn, 200)
  end

  defp tmp_prehen_home(label) do
    Path.join(
      System.tmp_dir!(),
      "prehen_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_prehen_home(nil), do: System.delete_env("PREHEN_HOME")
  defp restore_prehen_home(value), do: System.put_env("PREHEN_HOME", value)
end
