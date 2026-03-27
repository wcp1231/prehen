# Prehen Web Inbox Gateway Design

Date: 2026-03-28
Status: Draft approved in brainstorming

## 1. Summary

Prehen will add a first-class single-node Web inbox on top of the current Gateway MVP.

This inbox is not a multi-user product and not a chat SaaS surface. It is a control-plane Web UI for the current Prehen node that lets an operator:

- list current gateway sessions on this node
- create a new session with a selected agent
- switch between sessions
- view minimal in-memory chat history for a session
- submit messages through Phoenix Channels
- watch agent responses stream back in real time
- observe thin session status such as `starting`, `attached`, `running`, `idle`, `stopped`, or `crashed`

The goal is to complete the core chain:

`web user -> channel/http -> gateway -> local agent process -> gateway events -> web user`

## 2. Why This Exists

The current codebase already has the low-level pieces for:

- creating gateway sessions over HTTP
- joining a `session:<id>` Phoenix Channel
- submitting messages to a `SessionWorker`
- launching a local stdio-backed agent process per session
- streaming normalized events back through PubSub

What is still missing is a coherent user entrypoint.

The current Channel flow behaves more like a test/debug transport:

- a client must already know a `session_id`
- there is no node-level session inbox
- there is no minimal session history projection for UI switching
- there is no Web surface that behaves like a usable control console

This design fills that gap without changing the core architectural direction. Prehen remains a single-node Agent Gateway. The Web inbox is only a front door for the gateway, not a return to an in-process agent runtime.

## 3. Scope

### 3.1 In Scope

- one Prehen node
- one local agent process per gateway session
- Web as the first formal user-facing channel
- session list for the current node
- explicit session creation from the Web UI
- agent selection at session creation time
- server-provided default agent selection in the UI
- session switching in the Web UI
- minimal in-memory history for active and terminal sessions retained in the current node process
- real-time message submission and event streaming via Phoenix Channel
- thin session status shown in the UI

### 3.2 Out of Scope

- Telegram integration
- login, auth, or user identity
- per-user session isolation
- persistent history
- session recovery across restarts
- cross-node session aggregation
- multi-node routing
- tool mediation through Prehen
- full debug timeline UI

## 4. Product Model

The first Web surface should be treated as a node-local session inbox.

Properties:

- it shows all current sessions known to this Prehen node
- it does not try to distinguish users
- it is intended for a single-node operator or local developer workflow
- it uses the current gateway session id, exposed everywhere as `session_id`, as the stable unit of selection

The inbox is therefore closer to a node control console than to a general chat application.

## 5. User Experience

The intended first-pass user flow is:

1. User opens the Web inbox page.
2. Page loads available agents and current node sessions.
3. User clicks `New Session`.
4. User chooses an agent, or accepts the default agent.
5. Gateway creates a new session and launches the local agent process.
6. UI automatically switches to the new session.
7. UI loads minimal session history and joins the session Channel.
8. User submits a message from the message composer.
9. Gateway forwards the message to the agent session.
10. Agent emits events and text deltas.
11. Gateway updates session history projection and streams events to the UI.
12. User can switch to another session and back without losing in-memory history for still-live sessions.

If a session has already reached a terminal state, the user should still be able to select it from the list and inspect the in-memory history retained by the current node process.

## 6. Architectural Approach

The recommended implementation is a thin inbox control plane layered on top of the existing Gateway primitives.

This approach preserves the current boundary:

- Gateway owns route state, local process lifecycle, event fanout, and thin projections.
- Agent owns session truth, reasoning, and execution behavior.
- Web UI consumes Gateway-owned read models and Channel events.

The inbox should not directly reason about agent internals and should not depend on raw transport frames.

## 7. Core Backend Components

### 7.1 Session Index

The inbox needs a node-local list view over current sessions.

The session index should expose at least:

- `session_id`
- `agent_name`
- `status`
- `created_at`
- `last_event_at`
- `preview`

`preview` should be a minimal summary, usually the latest user or agent text.

The index can initially be derived from existing gateway registry state plus the in-memory history projection. It does not need to be a separate process on day one, but it should be implemented behind a dedicated module interface so that persistence or multi-node aggregation can be added later.

### 7.2 Session History

The inbox needs a UI-facing projection for minimal chat history.

This history is intentionally not:

- a canonical event store
- a persistent ledger
- a replay system

It is only a node-local in-memory projection retained by the current Prehen node process.

Retention rule for the first version:

- active sessions keep in-memory history while running
- terminal sessions keep their last in-memory history and remain readable until the Prehen node process restarts
- there is no persistent restore after restart

The history should retain only the UI-relevant record types:

- user messages
- agent output text
- error notes
- thin lifecycle/status notes when useful for UX

### 7.3 Inbox Control API

The Web inbox should use a control-plane-oriented HTTP surface.

Recommended endpoints:

- `GET /agents`
- `GET /inbox/sessions`
- `POST /inbox/sessions`
- `GET /inbox/sessions/:id`
- `GET /inbox/sessions/:id/history`
- `DELETE /inbox/sessions/:id`

Existing lower-level session endpoints may remain, but the inbox UI should consume inbox-oriented read models instead of assembling control-plane state itself.

For this design, `DELETE /inbox/sessions/:id` means terminate the live session if it is still running and mark it terminal in the inbox projections. It does not remove the session row or its in-memory history from the current process.

### 7.4 Session Channel

The current `session:<id>` Channel should remain the real-time path for the selected session.

The Channel should support:

- join selected session
- submit message to the selected session
- receive standardized events
- surface terminal session conditions

The first version should reuse the current `SessionChannel` rather than inventing a second socket protocol.

## 8. Data Flow

### 8.1 Initial Page Load

The page should request:

- available agents
- current node session list

No Channel connection is required until the user selects or creates a session.

### 8.2 Session Creation

When the user creates a session:

- Web calls `POST /inbox/sessions`
- Gateway selects the requested agent or falls back to a server-provided default
- Gateway launches a local `SessionWorker`
- transport handshake obtains `agent_session_id`
- session index receives a new entry
- history projection initializes empty history
- UI switches to the new session

### 8.3 Session Selection

When the user selects an existing session:

- Web loads `GET /inbox/sessions/:id/history`
- Web joins `session:<id>`
- prior selected session Channel is detached on the client side
- new events only update the active session stream view

### 8.4 Message Submission

When the user sends a message:

- Web pushes `submit` on the selected session Channel
- Gateway submits through `Surface.submit_message/3`
- `SessionWorker` forwards the message to the transport adapter
- adapter forwards the frame to the local agent process
- resulting events return through the existing gateway event path

### 8.5 Event Handling

Incoming events should drive two things:

- the real-time active session UI
- the node-local inbox read models

This means each gateway event can be consumed twice:

- as a socket push to the selected client
- as input to the session index/history projections

## 9. Session Status Model

The inbox should surface a thin, user-facing session state rather than raw transport details.

Recommended status vocabulary:

- `starting`
- `attached`
- `running`
- `idle`
- `stopped`
- `crashed`

Expected meaning in the first version:

- `attached` means the gateway session is bound to a live agent session and can accept messages
- `running` means the selected session is currently processing a submitted message or streaming output
- `idle` means the session remains live but is not actively processing output

These values should be derived from gateway lifecycle and event observations, not delegated to agent-specific private states.

The UI only needs to answer:

- did the session start
- is it currently able to receive messages
- is the agent actively producing output
- did the session end or fail

Terminal-state rule:

- `stopped` and `crashed` sessions remain visible in the inbox list for the lifetime of the current node process
- terminal sessions are read-only in the UI
- terminal sessions keep their last in-memory history available for detail view

## 10. History Model

The first history projection should store a simple timeline shape.

Recommended record kinds:

- `user_message`
- `assistant_message`
- `system_note`
- `error_note`

Each record should include:

- `id`
- `session_id`
- `kind`
- `text`
- `timestamp`
- optional `message_id`

Streaming agent deltas should be merged into the current `assistant_message` record rather than creating one UI record per delta.

This rule is critical for making the Web view usable.

## 11. Frontend Structure

The first UI should be a simple two-column layout.

### 11.1 Left Column

- new session action
- agent selector
- session list for the current node

Each session row should show:

- session id
- agent name
- thin status
- preview text
- relative or absolute last-updated time

### 11.2 Right Column

- selected session header
- selected session status
- history timeline
- composer input and send action

The right column should remain empty-state friendly when no session is selected.

## 12. Error Handling

The inbox should explicitly handle these cases:

### 12.1 Session Creation Failure

Examples:

- agent missing
- local worker spawn failure
- transport handshake failure

Behavior:

- creation panel displays a clear error
- current session selection does not change

### 12.2 Session Unavailable

Examples:

- selected session was stopped
- selected session worker disappeared
- Channel join fails because session is gone

Behavior:

- session stays visible in the list
- detail pane marks it `stopped` or `crashed`
- composer is disabled
- retained in-memory history is still readable if available

### 12.3 Message Submission Failure

Examples:

- registry entry exists but worker is no longer submit-capable
- channel submit fails due to missing worker

Behavior:

- UI should show an inline error/system note in the selected session timeline
- error should not be silently swallowed

If the target session is already terminal, the submit path should fail clearly and the UI should keep the session selected in read-only mode.

### 12.4 Channel Disconnect

Behavior:

- timeline stays rendered
- UI marks real-time connection as disconnected
- client may retry attach

## 13. Backend Testing Scope

The first implementation should cover:

- session list returns current node sessions
- session creation adds a new entry to the inbox list
- history projection records user message and agent output text
- status projection updates when sessions start or stop
- session Channel join and submit still function through the inbox flow
- delete/stop removes live accessibility, preserves terminal list visibility, and keeps retained in-memory history readable

## 14. Frontend Testing Scope

The first implementation should cover:

- page load requests agents and sessions
- new session auto-selects the created session
- switching sessions rebinds the active Channel
- incoming deltas merge into a single assistant message
- stopped or unavailable sessions show a disabled composer
- submit failures render a visible UI error note

## 15. Manual Verification Scope

Minimum manual verification should include:

1. Open the inbox page and confirm agents and sessions load.
2. Create a session and verify it appears in the list.
3. Send a message and verify the agent response streams into the timeline.
4. Create a second session and switch between them.
5. Stop one session and confirm the UI shows a terminal state.
6. Confirm stopped sessions remain selectable and still show retained history.
7. Confirm stopped sessions cannot accept new messages.

## 16. Implementation Boundary

This design intentionally stops before:

- Telegram transport/channel support
- browser/user identity
- persistent session history
- multi-node inbox aggregation
- session restore after restart
- agent-managed tool UIs

Those can be added later once the single-node Web message path is stable and operator-friendly.

## 17. Minimal API Contract Appendix

The first implementation should keep the inbox API intentionally small and JSON-first.

Canonical naming rule:

- the gateway-facing session identifier is always `session_id`
- the internal agent-owned identifier, when exposed at all, remains `agent_session_id`

### 17.1 `GET /agents`

Response shape:

```json
{
  "agents": [
    {
      "agent": "fake_stdio",
      "name": "fake_stdio",
      "default": true
    }
  ]
}
```

Default-agent rule for the first version:

- the server should mark one agent as default
- if no explicit default configuration exists, the first available agent in the ordered registry should be the default

### 17.2 `GET /inbox/sessions`

Response shape:

```json
{
  "sessions": [
    {
      "session_id": "gw_123",
      "agent_name": "fake_stdio",
      "status": "attached",
      "created_at": 1774625000000,
      "last_event_at": 1774625001234,
      "preview": "hi"
    }
  ]
}
```

### 17.3 `POST /inbox/sessions`

Request shape:

```json
{
  "agent": "fake_stdio"
}
```

Response shape:

```json
{
  "session_id": "gw_123",
  "agent": "fake_stdio",
  "status": "attached"
}
```

### 17.4 `GET /inbox/sessions/:id`

Response shape:

```json
{
  "session": {
    "session_id": "gw_123",
    "agent_name": "fake_stdio",
    "status": "attached",
    "created_at": 1774625000000,
    "last_event_at": 1774625001234
  }
}
```

### 17.5 `GET /inbox/sessions/:id/history`

Response shape:

```json
{
  "history": [
    {
      "id": "msg_1",
      "session_id": "gw_123",
      "kind": "user_message",
      "text": "hello",
      "timestamp": 1774625000000,
      "message_id": "request_1"
    },
    {
      "id": "msg_2",
      "session_id": "gw_123",
      "kind": "assistant_message",
      "text": "hi",
      "timestamp": 1774625000500,
      "message_id": "request_1"
    }
  ]
}
```

### 17.6 `DELETE /inbox/sessions/:id`

Behavior:

- if the session is live, terminate it
- if the session is already terminal, return success without changing retention semantics
- keep the session visible in the inbox list with terminal status
- keep retained in-memory history readable until node restart

UI wording rule:

- the user-facing action should be labeled as `Stop Session`
- the HTTP transport may still use `DELETE /inbox/sessions/:id` as the control-plane verb
