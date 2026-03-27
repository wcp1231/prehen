defmodule PrehenWeb.InboxPageControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  test "serves the inbox HTML shell with the browser hooks" do
    conn = get(build_conn(), "/inbox")
    body = html_response(conn, 200)

    assert body =~ "Prehen Inbox"
    assert body =~ "data-role=\"agent-select\""
    assert body =~ "data-role=\"session-list\""
    assert body =~ "data-role=\"history\""
    assert body =~ "data-role=\"composer\""
    assert body =~ "data-role=\"create-error\""
    assert body =~ "data-role=\"connection-state\""
    assert body =~ "/inbox.js"
  end
end
