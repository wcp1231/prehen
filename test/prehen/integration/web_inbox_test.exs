defmodule Prehen.Integration.WebInboxTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  test "lists sessions for the inbox page" do
    conn = get(build_conn(), "/inbox/sessions")

    assert %{"sessions" => sessions} = json_response(conn, 200)
    assert is_list(sessions)
  end

  test "lists agents with a default flag" do
    conn = get(build_conn(), "/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert is_list(agents)
    assert [%{"default" => true} | _] = agents
  end
end
