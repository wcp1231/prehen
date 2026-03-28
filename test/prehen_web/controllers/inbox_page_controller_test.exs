defmodule PrehenWeb.InboxPageControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint
  @inbox_js Path.expand("../../..", __DIR__) |> Path.join("priv/static/inbox.js")

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
    assert body =~ ~s(<script src="/inbox.js")
  end

  test "browser client source guards stale sockets and preserves session-scoped helpers" do
    source = File.read!(@inbox_js)

    assert source =~
             ~r/function handleSubmitError\(sessionId, response\) \{(?s:.*?)appendSystemNote\(sessionId, .*?\);(?s:.*?)setComposerDisabled\(true\);/

    assert source =~ "resolveJoinFailureFromHttp"
    assert source =~ "formatSessionTimestamp"
    assert source =~ ~r/function appendSystemNote\(sessionId, text\) \{(?s:.*?)session_id: sessionId/
    assert source =~ "entry.session_id === sessionId"
    assert source =~ "function updateAssistantPreview(sessionId, messageId, text)"
    assert source =~ ~r/socket\.addEventListener\("open", function \(\) \{\s*handleSocketOpen\(socket\);/
    assert source =~ ~r/socket\.addEventListener\("close", function \(\) \{\s*handleSocketClose\(socket\);/
    assert source =~ ~r/socket\.addEventListener\("message", function \(event\) \{\s*handleSocketMessage\(socket, event\);/
    assert source =~ ~r/function handleSocketOpen\(socket\) \{(?s:.*?)if \(socket !== state\.socket\) \{\s*return;\s*\}/
    assert source =~ ~r/function handleSocketClose\(socket\) \{(?s:.*?)if \(socket !== state\.socket\) \{\s*return;\s*\}/
    assert source =~ ~r/function handleSocketMessage\(socket, event\) \{(?s:.*?)if \(socket !== state\.socket\) \{\s*return;\s*\}/
  end
end
