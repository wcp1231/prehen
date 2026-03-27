defmodule PrehenWeb.InboxPageControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  test "serves the inbox HTML shell with the browser hooks" do
    conn = get(build_conn(), "/inbox")
    body = html_response(conn, 200)

    assert body =~ "Prehen Inbox"
    assert body =~ "data-role=\"session-list\""
    assert body =~ ~s(<script src="/inbox.js")
  end
end
