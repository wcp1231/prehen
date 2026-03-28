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

  test "serves the inbox static assets" do
    js_conn = get(build_conn(), "/inbox.js")
    css_conn = get(build_conn(), "/inbox.css")

    assert response(js_conn, 200) =~ "DOMContentLoaded"
    assert response(css_conn, 200) =~ ".inbox-shell"
  end

  test "browser client source keeps snapshot load failures separate from live attach failures" do
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
    assert source =~
             ~r/if \(eventName === "phx_error" \|\| eventName === "phx_close"\) \{(?s:.*?)joinRef === state\.activeChannel\.joinRef/

    assert source =~ "sortSessionsByActivity()"
    assert source =~ ~r/function sortSessionsByActivity\(\) \{/
    assert source =~ "renderCreateError(extractErrorMessage(error))"
    assert source =~ "clearSelectedSessionView(sessionId);"
    assert source =~ "friendlySubmitErrorMessage(response)"
    assert source =~ "Session is read-only."
    assert source =~
             ~r/applySelectedSessionSnapshot\(sessionId, detail, history\);(?s:.*?)if \(state\.selectedSessionId !== sessionId\) \{\s*return;\s*\}/

    assert source =~
             ~r/const detail = result\[0\]\.session;(?s:.*?)const history = result\[1\]\.history;(?s:.*?)applySelectedSessionSnapshot\(sessionId, detail, history\);(?s:.*?)try \{\s*await attachChannel\(sessionId\);/

    assert source =~
             ~r/try \{\s*await attachChannel\(sessionId\);\s*\} catch \(error\) \{\s*const handledError = handleLiveAttachError\(sessionId, error\);(?s:.*?)if \(handledError && handledError\.handled\) \{\s*return;\s*\}/

    assert source =~
             ~r/Promise\.all\(\[\s*fetchJson\(\"\/inbox\/sessions\/\" \+ encodeURIComponent\(sessionId\)\),\s*fetchJson\(\"\/inbox\/sessions\/\" \+ encodeURIComponent\(sessionId\) \+ \"\/history\"\)\s*\]\)(?s:.*?)catch \(error\) \{\s*const handledError = new Error\(extractErrorMessage\(error\)\);(?s:.*?)handleSessionSelectionError\(sessionId, handledError\);/

    assert source =~
             ~r/function handleLiveAttachError\(sessionId, error\) \{(?s:.*?)const handledError = error instanceof Error \? error : new Error\(extractErrorMessage\(error\)\);(?s:.*?)handledError\.handled = true;(?s:.*?)appendSystemNote\(sessionId, extractErrorMessage\(handledError\)\);(?s:.*?)return handledError;/

    assert source =~
             ~r/if \(body\.status === "ok"\) \{(?s:.*?)state\.activeChannel\.joinRef === ref/
    assert source =~ ~r/touchActivity: false/

    assert source =~ ~r/const sessionId = state\.selectedSessionId;(?s:.*?)submitMessage\(sessionId, text\)\.catch/
    assert source =~ ~r/appendSystemNote\(sessionId, extractErrorMessage\(error\)\);/
    assert source =~
             ~r/const isStillSelected = state\.selectedSessionId === sessionId;(?s:.*?)if \(isStillSelected\) \{\s*dom\.composerInput\.value = ""/

    assert source =~
             ~r/function clearSelectedSessionView\(sessionId\) \{(?s:.*?)dom\.composerInput\.value = ""(?s:.*?)setComposerDisabled\(true\);/

    assert source =~ "rejectPendingRepliesForSession(state.activeChannel.sessionId, \"Channel closed\")"
    assert source =~ ~r/function rejectPendingRepliesForSession\(sessionId, message\) \{/
  end
end
