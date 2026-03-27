# Prehen Single-Node Agent Gateway MVP Design

Date: 2026-03-27
Status: Implemented reference design

## 1. Goal

Build the first runnable version of the new Prehen architecture as a single-node local Agent Gateway.

This MVP should prove that Prehen can:

- accept client sessions over HTTP and Channels
- launch a local external agent process per session
- route messages to that process through a transport adapter
- stream standardized events back to clients
- keep agent logic and session truth outside Elixir

This document intentionally excludes multi-node scheduling as a build target. Cluster support is treated as a later extension point.

## 2. MVP Scope

### In Scope

- one Prehen node
- one local agent process per session
- explicit or auto-selected local agent profile
- HTTP session control surface
- Phoenix Channel streaming surface
- transport abstraction with one real implementation
- ACP-inspired minimal message/event model
- gateway-level observability

### Out of Scope

- OTP multi-node routing
- cross-node execution
- session migration
- platform-managed memory
- tool proxying through Prehen
- long-lived multiplexed agent daemons
- complete ACP compliance

## 3. Target User Experience

The MVP should support the following flow:

1. Client creates a gateway session.
2. Prehen selects an agent profile.
3. Prehen launches a local agent process.
4. Agent handshake returns `agent_session_id`.
5. Client subscribes to the session channel.
6. Client sends messages through the gateway.
7. Agent streams deltas, statuses, and results.
8. Prehen forwards standardized envelopes to the client.

The client should never need to know whether the agent speaks stdio, socket, or some later transport.

## 4. Core MVP Components

### 4.1 Gateway Surface

The external surface should include both:

- HTTP endpoints for session lifecycle and message submission
- Phoenix Channels for real-time event streaming

Recommended initial responsibilities:

- `POST /sessions`
- `POST /sessions/:id/messages`
- `GET /sessions/:id`
- `GET /agents`
- `channel: session:<gateway_session_id>`

HTTP is control-plane oriented. Channels are event-plane oriented.

### 4.2 Session Registry

Single-node MVP still needs a lightweight registry for:

- `gateway_session_id`
- selected agent profile
- process pid/reference
- current attach status
- current `agent_session_id`

This is route state only, not canonical conversation state.

### 4.3 Local Agent Supervisor

For each session:

- launch the configured agent command
- monitor process lifetime
- own transport adapter state
- notify gateway on exit or handshake failure

One session maps to one supervised agent child process.

### 4.4 Transport Adapter Interface

The MVP should define the abstraction even if only one adapter is implemented.

Required behaviors:

- start process/session
- send message frame
- send control frame
- receive inbound frames
- surface diagnostics
- stop process/session

### 4.5 Event Normalizer

All inbound agent frames should be mapped to a stable gateway envelope before reaching:

- channel pushes
- HTTP read models
- gateway observability

This keeps clients independent from any individual agent's raw protocol.

## 5. First Transport Choice

The first concrete transport should be `stdio + JSON Lines`.

Rationale:

- best fit for locally supervised processes
- simple startup and shutdown semantics
- low dependency overhead
- easy to adapt for tools like Codex-style or pi-coding-agent-style wrappers

Implementation constraints:

- one JSON object per line
- `stdin` for gateway-to-agent frames
- `stdout` for agent-to-gateway frames
- `stderr` treated as diagnostics, not protocol payload

## 6. Minimal ACP-Inspired Protocol Subset

The MVP internal protocol should align with ACP-style semantics without trying to replicate the full standard.

### 6.1 Core Objects

- Agent profile
- Session
- Message
- Event

### 6.2 Handshake

Initial handshake should support:

- `session.open`
- `session.opened`

`session.open` includes:

- `gateway_session_id`
- selected agent/profile metadata
- workspace info
- optional client/session metadata

`session.opened` includes:

- `agent_session_id`
- readiness confirmation
- optional capability declaration
- optional reattach/recovery declaration

### 6.3 Message Submission

Primary inbound messages:

- `session.message`
- `session.control`

`session.message` should preserve an extensible shape:

- `message_id`
- `role`
- `parts`
- `metadata`

The system should not collapse input to plain text only, even if the initial UI sends text.

### 6.4 Agent Output Events

Primary outbound events:

- `session.status`
- `session.output.delta`
- `session.output.completed`
- `session.tool`
- `session.error`
- `session.closed`

Tool events are not normalized deeply in MVP because tool semantics remain agent-owned.

## 7. Gateway Envelope Shape

Every event exposed to clients should have a thin stable envelope:

- `type`
- `gateway_session_id`
- `agent_session_id`
- `agent`
- `node`
- `seq`
- `timestamp`
- `payload`
- `metadata`

The envelope should be stable across all agent adapters.

## 8. Error Semantics

The MVP should distinguish gateway-owned failure from agent-owned failure.

### 8.1 Gateway Errors

- agent profile not found
- session route missing
- process spawn failed
- transport handshake failed
- transport disconnected
- session channel not attached

### 8.2 Agent Errors

- model/provider failures
- workspace/tool failures
- agent internal exceptions
- rejected or interrupted session actions

Gateway errors should be mapped to structured `gateway_error` forms. Agent failures should be surfaced as `agent_error` events with minimal translation.

## 9. Reattach and Recovery

The MVP should define conservative semantics:

- channel reconnect may reattach to a still-live gateway session
- agent restart does not imply session recovery
- Prehen restart does not guarantee active session restoration
- session continuity depends on agent support, not on platform reconstruction

This constraint should be explicit in both implementation and documentation.

## 10. Impact on Existing Modules

### 10.1 Replace or Rewrite

- `Prehen.Agent.Runtime`
- `Prehen.Agent.Session`
- `Prehen.Agent.Backends.*`
- platform `Memory` flow in the current runtime path

### 10.2 Keep with New Responsibility

- `Prehen.Client.Surface` becomes gateway facade
- `PrehenWeb.SessionChannel` becomes route-and-stream channel
- `PrehenWeb.Router` and controllers remain the HTTP surface
- selected observability code becomes gateway trace/logging

### 10.3 Temporary Compatibility

The implementation has already cut over to the gateway-first path. Any remaining compatibility surface must fail explicitly or be removed in later cleanup, and it must not reintroduce the old runtime as the active core.

## 11. Acceptance Criteria

The MVP is successful when all of the following are true:

1. a client can create a session over HTTP
2. Prehen launches a local agent process for that session
3. the agent handshake returns an `agent_session_id`
4. the client can subscribe to session events over Channels
5. the client can send a message and receive streamed output
6. the agent can emit a final result or error
7. Prehen can report process exit and transport failure cleanly

## 12. Deferred Follow-Up

After the MVP works, the next change should add:

- node registry
- remote route selection
- OTP cluster forwarding
- remote session attachment semantics

Only after that should the project revisit:

- tool mediation by Prehen
- persistent gateway event logging
- stronger ACP/A2A compatibility goals
