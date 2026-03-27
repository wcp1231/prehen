# Web Inbox Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single-node Web inbox so operators can list sessions, create/select sessions, send messages through the Gateway, and read streaming agent replies from a browser.

**Architecture:** Keep the current single-node gateway and stdio session worker model intact. Add a node-local inbox projection for session list and in-memory history, expose inbox-oriented HTTP endpoints, and serve a minimal HTML + vanilla JS page that uses HTTP for control-plane reads and Phoenix Channels for real-time messaging.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, Phoenix Channels, ExUnit, stdio JSON Lines transport, vanilla browser JavaScript, static assets in `priv/static`

---

## Scope Check

This plan intentionally covers only:

- node-local Web inbox page
- session list for the current node
- explicit session creation with agent selection
- in-memory session history
- channel-driven message submission and streaming updates
- thin session statuses and terminal read-only behavior

It does not cover:

- Telegram
- auth or per-user isolation
- persistent history
- multi-node routing
- tool mediation
- new frontend build tooling

## File Structure

### New files

- `lib/prehen/gateway/inbox_projection.ex`
  Node-local GenServer that stores session list rows, session detail fields, and minimal in-memory history.
- `lib/prehen/gateway/inbox.ex`
  Thin facade for inbox list/detail/history/create/stop operations used by controllers and future callers.
- `lib/prehen_web/controllers/inbox_controller.ex`
  JSON control-plane endpoints for inbox list, create, detail, history, and stop.
- `lib/prehen_web/controllers/inbox_page_controller.ex`
  Serves the HTML shell for the Web inbox page.
- `lib/prehen_web/inbox_page.ex`
  Builds the minimal HTML document and wires in static JS/CSS without adding a frontend toolchain.
- `priv/static/inbox.js`
  Browser logic for page load, session selection, channel attach, submit flow, and UI updates.
- `priv/static/inbox.css`
  Minimal two-column styling for the inbox page.
- `test/prehen/gateway/inbox_projection_test.exs`
  Covers session row projection, status transitions, preview updates, and retained history.
- `test/prehen/integration/web_inbox_test.exs`
  Covers inbox HTTP endpoints plus controller-facing session lifecycle semantics.
- `test/prehen_web/controllers/inbox_page_controller_test.exs`
  Covers the HTML shell route and required DOM hooks for the browser client.

### Files to modify

- `lib/prehen/gateway/supervisor.ex`
  Start the inbox projection alongside the registry and worker supervisor.
- `lib/prehen/gateway/session_worker.ex`
  Publish lifecycle and history updates into the inbox projection on start, submit, inbound event, and terminate.
- `lib/prehen/gateway/session_registry.ex`
  Keep route data focused, but expose whatever inbox integration needs without turning it into a history store.
- `lib/prehen/client/surface.ex`
  Reuse existing session create/submit/stop behavior while exposing inbox-friendly reads through the new facade.
- `lib/prehen_web/router.ex`
  Add `/inbox` HTML route and `/inbox/sessions` JSON routes without disturbing existing API endpoints.
- `lib/prehen_web/endpoint.ex`
  Serve `priv/static` assets so the HTML shell can load `inbox.js` and `inbox.css`.
- `lib/prehen_web/controllers/agent_controller.ex`
  Include `default` metadata and explicit empty-registry behavior for the inbox page.
- `lib/prehen_web/channels/session_channel.ex`
  Keep the existing session channel but improve join/submit payloads for the inbox page and terminal read-only states.
- `lib/prehen_web/serializers/event_serializer.ex`
  Preserve fields the inbox browser client needs for message/history updates.
- `test/prehen_web/channels/session_channel_test.exs`
  Extend coverage for inbox-oriented join and submit behavior.
- `test/prehen/integration/platform_runtime_test.exs`
  Keep current gateway MVP flows green while inbox routes land.
- `README.md`
  Add the new Web inbox entrypoint and local verification steps.
- `docs/architecture/current-system.md`
  Note that Web is now the first formal user-facing channel on top of the gateway.

### Deliberate decomposition choices

- No SPA framework or asset bundler in v1. The browser client is plain JS so the plan stays focused on gateway behavior rather than frontend tooling.
- `InboxProjection` owns UI read models. `SessionRegistry` stays a route/worker lookup store rather than expanding into an all-purpose gateway database.
- The inbox HTML page is separated from the JSON inbox controller so server-side page rendering and control-plane API logic do not accumulate in one controller file.

## Task 1: Lock the Inbox Contract in Tests

**Files:**
- Create: `test/prehen/gateway/inbox_projection_test.exs`
- Create: `test/prehen/integration/web_inbox_test.exs`
- Create: `test/prehen_web/controllers/inbox_page_controller_test.exs`
- Modify: `test/prehen_web/channels/session_channel_test.exs`

- [ ] **Step 1: Write the failing inbox projection test**

```elixir
defmodule Prehen.Gateway.InboxProjectionTest do
  use ExUnit.Case, async: false

  alias Prehen.Gateway.InboxProjection

  test "tracks session row, preview, and retained history" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_inbox_1",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.user_message(%{
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hello"
             })

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_inbox_1",
               message_id: "request_1",
               text: "hi"
             })

    assert {:ok, row} = InboxProjection.fetch_session("gw_inbox_1")
    assert row.preview == "hi"

    assert {:ok, history} = InboxProjection.fetch_history("gw_inbox_1")
    assert Enum.map(history, & &1.kind) == [:user_message, :assistant_message]
  end

  test "merges multiple deltas for one assistant message" do
    assert :ok =
             InboxProjection.session_started(%{
               session_id: "gw_delta_merge",
               agent_name: "fake_stdio",
               created_at: 1_774_625_000_000
             })

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_delta_merge",
               message_id: "request_merge",
               text: "he"
             })

    assert :ok =
             InboxProjection.agent_delta(%{
               session_id: "gw_delta_merge",
               message_id: "request_merge",
               text: "llo"
             })

    assert {:ok, history} = InboxProjection.fetch_history("gw_delta_merge")

    assert [
             %{kind: :assistant_message, message_id: "request_merge", text: "hello"}
           ] = history
  end
end
```

- [ ] **Step 2: Run the projection test to verify it fails**

Run: `mix test test/prehen/gateway/inbox_projection_test.exs`

Expected: FAIL because `Prehen.Gateway.InboxProjection` does not exist yet.

- [ ] **Step 3: Write the failing inbox HTTP test**

```elixir
defmodule Prehen.Integration.WebInboxTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  test "lists sessions for the inbox page" do
    conn = get(build_conn(), "/inbox/sessions")

    assert %{"sessions" => sessions} = json_response(conn, 200)
    assert is_list(sessions)
  end

  test "lists agents with default metadata and handles an empty registry" do
    conn = get(build_conn(), "/agents")
    assert %{"agents" => agents} = json_response(conn, 200)
    assert is_list(agents)
  end
end
```

- [ ] **Step 4: Run the inbox HTTP test to verify it fails**

Run: `mix test test/prehen/integration/web_inbox_test.exs`

Expected: FAIL because `/inbox/sessions` is not routed yet.

- [ ] **Step 5: Write the failing inbox page shell test**

```elixir
defmodule PrehenWeb.InboxPageControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  @endpoint PrehenWeb.Endpoint

  test "serves the inbox HTML shell" do
    conn = get(build_conn(), "/inbox")
    body = html_response(conn, 200)

    assert body =~ "Prehen Inbox"
    assert body =~ "data-role=\"session-list\""
    assert body =~ "/inbox.js"
  end
end
```

- [ ] **Step 6: Run the page shell test to verify it fails**

Run: `mix test test/prehen_web/controllers/inbox_page_controller_test.exs`

Expected: FAIL because `/inbox` does not exist yet.

- [ ] **Step 7: Extend the channel test with inbox behavior**

Add a failing test to `test/prehen_web/channels/session_channel_test.exs`:

```elixir
test "returns a submit ack payload the inbox browser can correlate" do
  fake_profile = %Prehen.Agents.Profile{
    name: "fake_stdio",
    command: ["mix", "run", "--no-start", "test/support/fake_stdio_agent.exs"]
  }

  registry_pid = Process.whereis(Prehen.Agents.Registry)
  original = :sys.get_state(registry_pid)

  :sys.replace_state(registry_pid, fn _ ->
    %{ordered: [fake_profile], by_name: %{"fake_stdio" => fake_profile}}
  end)

  on_exit(fn ->
    :sys.replace_state(registry_pid, fn _ -> original end)
  end)

  assert {:ok, %{session_id: session_id}} =
           Prehen.Client.Surface.create_session(agent: "fake_stdio")

  on_exit(fn -> Prehen.Client.Surface.stop_session(session_id) end)

  {:ok, _, socket} =
    socket(PrehenWeb.UserSocket)
    |> subscribe_and_join(PrehenWeb.SessionChannel, "session:#{session_id}")

  ref = push(socket, "submit", %{"text" => "hello"})
  assert_reply ref, :ok, %{"request_id" => _request_id}
end
```

- [ ] **Step 8: Do not commit yet**

Carry the red tests into Task 2 so the first implementation commit lands green.

## Task 2: Add the Inbox Projection and Gateway Facade

**Files:**
- Create: `lib/prehen/gateway/inbox_projection.ex`
- Create: `lib/prehen/gateway/inbox.ex`
- Modify: `lib/prehen/gateway/supervisor.ex`
- Modify: `test/prehen/gateway/inbox_projection_test.exs`

- [ ] **Step 1: Implement the failing projection test with the smallest in-memory model**

```elixir
defmodule Prehen.Gateway.InboxProjection do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def session_started(attrs), do: GenServer.call(__MODULE__, {:session_started, attrs})
  def fetch_session(session_id), do: GenServer.call(__MODULE__, {:fetch_session, session_id})
  def fetch_history(session_id), do: GenServer.call(__MODULE__, {:fetch_history, session_id})
end
```

- [ ] **Step 2: Track only the fields required by the spec**

```elixir
%{
  sessions: %{
    "gw_1" => %{
      session_id: "gw_1",
      agent_name: "fake_stdio",
      status: :attached,
      created_at: 1_774_625_000_000,
      last_event_at: 1_774_625_000_000,
      preview: nil
    }
  },
  history: %{
    "gw_1" => [
      %{id: "msg_1", kind: :user_message, text: "hello"}
    ]
  }
}
```

The merge invariant is required:

```elixir
[
  %{kind: :assistant_message, message_id: "request_merge", text: "hello"}
]
```

Do not append one assistant history record per delta.

- [ ] **Step 3: Add the inbox facade used by controllers**

```elixir
defmodule Prehen.Gateway.Inbox do
  alias Prehen.Client.Surface
  alias Prehen.Gateway.InboxProjection

  def list_sessions, do: InboxProjection.list_sessions()
  def session_detail(session_id), do: InboxProjection.fetch_session(session_id)
  def history(session_id), do: InboxProjection.fetch_history(session_id)
  def create_session(opts), do: Surface.create_session(opts)
  def stop_session(session_id), do: Surface.stop_session(session_id)
end
```

- [ ] **Step 4: Start the projection under the gateway supervisor**

Run: `mix test test/prehen/gateway/inbox_projection_test.exs`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/prehen/gateway/inbox_projection.ex lib/prehen/gateway/inbox.ex lib/prehen/gateway/supervisor.ex test/prehen/gateway/inbox_projection_test.exs
git commit -m "feat: add gateway inbox projection"
```

## Task 3: Wire Session Lifecycle, History, and Status into the Projection

**Files:**
- Modify: `lib/prehen/gateway/session_worker.ex`
- Modify: `lib/prehen/gateway/session_registry.ex`
- Modify: `lib/prehen/client/surface.ex`
- Modify: `test/prehen/gateway/inbox_projection_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`

- [ ] **Step 1: Add a failing test for submit and terminal retention**

Add to `test/prehen/gateway/inbox_projection_test.exs`:

```elixir
test "keeps terminal session history readable after stop" do
  InboxProjection.session_started(%{
    session_id: "gw_terminal",
    agent_name: "fake_stdio",
    created_at: 1_774_625_000_000
  })

  InboxProjection.user_message(%{
    session_id: "gw_terminal",
    message_id: "request_terminal",
    text: "hello"
  })

  InboxProjection.session_stopped(%{session_id: "gw_terminal"})

  assert {:ok, row} = InboxProjection.fetch_session("gw_terminal")
  assert row.status == :stopped

  assert {:ok, history} = InboxProjection.fetch_history("gw_terminal")
  assert Enum.any?(history, &(&1.kind == :user_message))
end
```

- [ ] **Step 2: Run the targeted test to verify it fails**

Run: `mix test test/prehen/gateway/inbox_projection_test.exs`

Expected: FAIL because session lifecycle hooks are incomplete.

- [ ] **Step 3: Record user messages and agent deltas from the gateway hot path**

In `SessionWorker`, wire projection updates in these places:

```elixir
InboxProjection.session_started(%{
  session_id: gateway_session_id,
  agent_name: profile.name,
  created_at: now_ms
})

InboxProjection.user_message(%{
  session_id: state.gateway_session_id,
  message_id: message.message_id,
  text: extract_user_text(message.parts)
})

InboxProjection.agent_delta(%{
  session_id: state.gateway_session_id,
  message_id: frame_message_id(payload),
  text: frame_text(payload)
})
```

- [ ] **Step 4: Mark terminal sessions without deleting their retained history**

```elixir
InboxProjection.session_stopped(%{
  session_id: state.gateway_session_id,
  status: terminal_status(reason)
})
```

- [ ] **Step 5: Run the focused gateway tests**

Run: `mix test test/prehen/gateway/inbox_projection_test.exs test/prehen/integration/platform_runtime_test.exs`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/prehen/gateway/session_worker.ex lib/prehen/gateway/session_registry.ex lib/prehen/client/surface.ex test/prehen/gateway/inbox_projection_test.exs test/prehen/integration/platform_runtime_test.exs
git commit -m "feat: project inbox session history"
```

## Task 4: Add Inbox JSON Endpoints and Default-Agent Metadata

**Files:**
- Create: `lib/prehen_web/controllers/inbox_controller.ex`
- Modify: `lib/prehen_web/router.ex`
- Modify: `lib/prehen_web/controllers/agent_controller.ex`
- Modify: `test/prehen/integration/web_inbox_test.exs`

- [ ] **Step 1: Extend the failing HTTP tests to cover create/detail/history/stop**

```elixir
test "creates, reads, and stops inbox sessions" do
  conn = post(build_conn(), "/inbox/sessions", %{"agent" => "fake_stdio"})
  assert %{"session_id" => session_id, "status" => "attached", "agent" => "fake_stdio"} =
           json_response(conn, 201)

  conn = get(build_conn(), "/inbox/sessions/#{session_id}")
  assert %{"session" => %{"session_id" => ^session_id}} = json_response(conn, 200)

  conn = get(build_conn(), "/inbox/sessions/#{session_id}/history")
  assert %{"history" => history} = json_response(conn, 200)
  assert is_list(history)

  conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
  assert response(conn, 204)
end

test "returns a structured error when session creation fails" do
  conn = post(build_conn(), "/inbox/sessions", %{"agent" => "missing_agent"})

  assert %{"error" => %{"type" => "unprocessable_entity"}} = json_response(conn, 422)
end
```

- [ ] **Step 2: Run the inbox HTTP tests to verify they fail**

Run: `mix test test/prehen/integration/web_inbox_test.exs`

Expected: FAIL because the inbox JSON routes do not exist.

- [ ] **Step 3: Implement the inbox controller around the gateway inbox facade**

```elixir
def create(conn, params) do
  opts = build_create_opts(params)

  with {:ok, session} <- Inbox.create_session(opts),
       {:ok, detail} <- Inbox.session_detail(session.session_id) do
    conn
    |> put_status(:created)
    |> json(%{
      session_id: session.session_id,
      agent: detail.agent_name,
      status: Atom.to_string(detail.status)
    })
  end
end
```

- [ ] **Step 4: Make `/agents` inbox-friendly and test the empty-registry case**

Return:

```elixir
%{
  agent: profile.name,
  name: profile.name,
  default: profile.name == default_agent_name
}
```

If there are no agents, return `{"agents": []}`.

Add a focused test like:

```elixir
test "GET /agents marks one default agent when profiles exist" do
  conn = get(build_conn(), "/agents")
  assert %{"agents" => [first | _]} = json_response(conn, 200)
  assert Map.has_key?(first, "default")
end
```

- [ ] **Step 5: Implement explicit create-failure behavior for the inbox API**

Creation failures must return a stable error payload through the fallback controller so the browser can render the error without changing the current selection.

Examples to preserve:

- missing/unknown agent
- worker spawn failure
- transport handshake failure

- [ ] **Step 6: Run the HTTP integration tests**

Run: `mix test test/prehen/integration/web_inbox_test.exs test/prehen/integration/platform_runtime_test.exs`

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/prehen_web/controllers/inbox_controller.ex lib/prehen_web/controllers/agent_controller.ex lib/prehen_web/router.ex test/prehen/integration/web_inbox_test.exs
git commit -m "feat: add inbox control plane api"
```

## Task 5: Improve SessionChannel for the Inbox Browser

**Files:**
- Modify: `lib/prehen_web/channels/session_channel.ex`
- Modify: `lib/prehen_web/serializers/event_serializer.ex`
- Modify: `test/prehen_web/channels/session_channel_test.exs`

- [ ] **Step 1: Add the failing channel tests for status-rich join and terminal read-only behavior**

```elixir
test "join returns session metadata for the inbox client" do
  :ok =
    SessionRegistry.put(%{
      gateway_session_id: "gw_join_meta",
      worker_pid: self(),
      agent_name: "fake_stdio",
      agent_session_id: "agent_gw_join_meta",
      status: :attached
    })

  assert {:ok, %{"session_id" => "gw_join_meta", "status" => "attached"}, _socket} =
           socket(PrehenWeb.UserSocket)
           |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_join_meta")
end
```

- [ ] **Step 2: Run the channel tests to verify they fail**

Run: `mix test test/prehen_web/channels/session_channel_test.exs`

Expected: FAIL because join payload and submit semantics are still too thin.

- [ ] **Step 3: Return inbox-friendly join data and fail submits clearly for terminal sessions**

```elixir
{:ok, %{"session_id" => session_id, "status" => status, "agent_name" => agent_name}, socket}
```

For submit failure:

```elixir
{:reply, {:error, %{"reason" => "session_unavailable", "session_id" => socket.assigns.session_id}}, socket}
```

- [ ] **Step 4: Preserve the event fields needed by the browser client**

The serialized event must keep:

- `type`
- `gateway_session_id`
- `agent_session_id`
- `payload.text`
- `payload.message_id`

- [ ] **Step 5: Run the focused channel and serializer tests**

Run: `mix test test/prehen_web/channels/session_channel_test.exs test/prehen_web/serializers/event_serializer_test.exs`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/prehen_web/channels/session_channel.ex lib/prehen_web/serializers/event_serializer.ex test/prehen_web/channels/session_channel_test.exs
git commit -m "feat: adapt session channel for inbox clients"
```

## Task 6: Serve the Inbox Page and Minimal Static Assets

**Files:**
- Create: `lib/prehen_web/controllers/inbox_page_controller.ex`
- Create: `lib/prehen_web/inbox_page.ex`
- Create: `priv/static/inbox.js`
- Create: `priv/static/inbox.css`
- Modify: `lib/prehen_web/endpoint.ex`
- Modify: `lib/prehen_web/router.ex`
- Modify: `test/prehen_web/controllers/inbox_page_controller_test.exs`

- [ ] **Step 1: Expand the page shell test to require the DOM hooks the JS needs**

```elixir
assert body =~ "data-role=\"agent-select\""
assert body =~ "data-role=\"session-list\""
assert body =~ "data-role=\"history\""
assert body =~ "data-role=\"composer\""
assert body =~ "data-role=\"create-error\""
assert body =~ "data-role=\"connection-state\""
```

- [ ] **Step 2: Run the page shell test to verify it fails**

Run: `mix test test/prehen_web/controllers/inbox_page_controller_test.exs`

Expected: FAIL because the page shell is still missing.

- [ ] **Step 3: Add static serving and an HTML shell route**

In `Endpoint`:

```elixir
plug Plug.Static,
  at: "/",
  from: :prehen,
  only: ~w(inbox.js inbox.css)
```

In `Router`:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
end

scope "/", PrehenWeb do
  pipe_through :browser
  get "/inbox", InboxPageController, :show
end
```

- [ ] **Step 4: Implement the browser client in plain JS**

The first `inbox.js` should do only this:

```javascript
await loadAgentsAndSessions()
renderSessionList()
createSession()
renderCreateError(error)
selectSession(sessionId)
attachChannel(sessionId)
submitMessage(sessionId, text)
applyGatewayEvent(event)
setComposerDisabled(disabled)
appendSystemNote(sessionId, text)
renderSelectedSessionStatus(status)
setConnectionState(state)
scheduleReattach(sessionId)
```

Do not add a build step or framework.

When the selected session becomes terminal or submit returns an error:

- keep the session selected
- append a visible system/error note into the timeline
- disable the composer until the user switches to a live session

When session creation fails:

- keep the currently selected session unchanged
- render the create error in the dedicated create-error area
- do not clear the session list or current history pane

When the socket disconnects or closes:

- render a disconnected connection-state indicator
- keep the selected session and current history visible
- attempt to reattach the active session channel after reconnect
- clear the disconnected indicator after successful reattach

- [ ] **Step 5: Run the page and integration tests**

Run: `mix test test/prehen_web/controllers/inbox_page_controller_test.exs test/prehen/integration/web_inbox_test.exs`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/prehen_web/controllers/inbox_page_controller.ex lib/prehen_web/inbox_page.ex lib/prehen_web/endpoint.ex lib/prehen_web/router.ex priv/static/inbox.js priv/static/inbox.css test/prehen_web/controllers/inbox_page_controller_test.exs
git commit -m "feat: add web inbox page"
```

## Task 7: Final Integration, Docs, and Manual Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`
- Modify: `test/prehen/integration/web_inbox_test.exs`
- Modify: `test/prehen_web/channels/session_channel_test.exs`
- Modify: `test/prehen/cli_test.exs` (only if existing CLI assumptions regress)

- [ ] **Step 1: Add the final end-to-end test for create -> channel submit -> stop semantics**

```elixir
test "web inbox flow can create over HTTP and submit over SessionChannel" do
  conn = post(build_conn(), "/inbox/sessions", %{"agent" => "fake_stdio"})
  assert %{"session_id" => session_id} = json_response(conn, 201)

  {:ok, _, socket} =
    socket(PrehenWeb.UserSocket)
    |> subscribe_and_join(PrehenWeb.SessionChannel, "session:#{session_id}")

  ref = push(socket, "submit", %{"text" => "hello"})
  assert_reply ref, :ok, %{"request_id" => request_id}
  assert_push "event", %{"type" => "session.output.delta", "payload" => %{"message_id" => ^request_id}}

  conn = delete(build_conn(), "/inbox/sessions/#{session_id}")
  assert response(conn, 204)

  conn = get(build_conn(), "/inbox/sessions/#{session_id}/history")
  assert %{"history" => history} = json_response(conn, 200)
  assert history != []
end
```

- [ ] **Step 2: Run the full targeted suite**

Run: `mix test test/prehen/gateway/inbox_projection_test.exs test/prehen/integration/web_inbox_test.exs test/prehen_web/channels/session_channel_test.exs test/prehen_web/controllers/inbox_page_controller_test.exs`

Expected: PASS

- [ ] **Step 3: Update operator-facing docs**

Document:

- the new `/inbox` entrypoint
- the node-local/non-persistent behavior
- the fact that stopped sessions remain visible until restart

- [ ] **Step 4: Run full verification**

Run: `mix test`
Expected: `0 failures`

Run: `mix xref graph --label compile`
Expected: succeeds without introducing old-runtime compile dependencies

- [ ] **Step 5: Do the manual browser smoke checklist**

1. Open `/inbox`
2. Create a session
3. Send a message
4. Create a second session
5. Switch between sessions
6. Stop one session
7. Confirm stopped session still renders retained history and rejects submit

- [ ] **Step 6: Commit**

```bash
git add README.md docs/architecture/current-system.md test/prehen/integration/web_inbox_test.exs
git commit -m "docs: describe web inbox gateway flow"
```
