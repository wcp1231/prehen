# Prehen Current Architecture (As-Is)

_Last updated: 2026-04-01_

This document describes the current single-node gateway architecture as implemented today.

Prehen is now a local-first Agent Gateway and control plane:

- external local agent processes own session truth and execution semantics
- one gateway session maps to one local agent process
- users select supported agent profiles, not raw executable implementations
- HTTP and Phoenix Channels are the primary client surface
- `/inbox` is the operator-facing browser entrypoint on the local node
- the first supported transport is `stdio + JSON Lines`
- retained inbox rows and history are in-memory only on the current node

## 1. Layer Overview

The current hot path is:

1. `Prehen` public API
2. `Prehen.Client.Surface`
3. `Prehen.Gateway.Router`
4. `Prehen.Gateway.SessionWorker`
5. `Prehen.Agents.Transports.Stdio` or another registered transport adapter
6. `PrehenWeb` HTTP controllers and `PrehenWeb.SessionChannel`

The gateway also keeps a small in-memory trace collector for gateway events only.

```text
CLI / HTTP / Channel clients
    |
    v
Prehen
    |
    v
Prehen.Client.Surface
    |
    v
Prehen.Gateway.Router
    |
    +--> Prehen.Agents.Registry (supported profiles + internal implementation mapping)
    |
    v
Prehen.Gateway.SessionWorker
    |
    +--> Prehen.Gateway.SessionRegistry
    +--> Prehen.Observability.TraceCollector
    +--> transport adapter
             |
             +--> local external agent process
```

The inbox UI, inbox JSON endpoints, session registry, and retained history all operate against node-local in-memory state. There is no durable recovery or cross-node visibility.

## 2. Component Responsibilities

### 2.1 `Prehen`

- public API facade
- forwards to the gateway-backed client surface
- exposes the current gateway session helpers only

### 2.2 `Prehen.Client.Surface`

- creates gateway sessions
- submits messages to the active session worker
- reads gateway session status
- stops gateway sessions
- exposes `run/2` as a gateway-backed CLI compatibility path

### 2.3 `Prehen.Gateway.Router`

- selects a supported agent profile by name
- treats the phase-1 `agent` wire value as a profile identifier
- honors explicit profile selection when provided
- otherwise picks the default supported profile from the registry
- binds the selected profile to its internal implementation before worker startup

### 2.4 `Prehen.Agents.Registry`

- stores configured profiles and implementations
- runs wrapper support validation at startup so only supported profiles remain user-visible
- returns supported profiles for `/agents` and default selection
- keeps implementation lookup internal to router and worker startup

### 2.5 `Prehen.Gateway.SessionWorker`

- one worker per gateway session
- starts the configured transport adapter
- opens the external local agent process
- records and broadcasts normalized gateway events
- owns the attachment between `gateway_session_id` and `agent_session_id`

### 2.6 `Prehen.Gateway.SessionRegistry`

- stores route state only
- tracks `gateway_session_id`, worker pid, agent name, agent session id, and attach status
- does not own canonical session truth
- keeps terminal route metadata available for status and idempotent stop handling

### 2.7 `Prehen.Observability.TraceCollector`

- holds a small in-memory trace for gateway events
- is used for immediate trace reads in `run/2` and related flows
- does not persist session history

### 2.8 `Prehen.Gateway.InboxProjection`

- keeps inbox session summaries and message history for the browser surface
- is rebuilt from live events only during the current node lifetime
- keeps stopped sessions readable after stop, but only until restart

### 2.9 `Prehen.Agents.Transports.Stdio`

- concrete `stdio + JSON Lines` transport
- starts the agent child process
- sends and receives JSON frames
- treats `stderr` as diagnostics

### 2.10 `PrehenWeb`

- HTTP controllers expose supported profiles through `GET /agents`
- session create surfaces continue to use the `agent` wire field, but its value is now a supported profile name
- provider/model defaults come from the selected profile unless the request overrides them
- `/inbox` serves the browser shell for operators
- `PrehenWeb.SessionChannel` subscribes to `session:<gateway_session_id>` and forwards normalized envelopes
- `PrehenWeb.EventSerializer` strips runtime-only fields and keeps the client payload JSON safe

## 3. Current Data Flow

### 3.1 Session Creation

1. Client calls `POST /sessions`, `POST /inbox/sessions`, or `Prehen.create_session/1`.
2. `Surface.create_session/1` asks the router for a supported profile.
3. The router resolves that profile to its internal implementation.
4. `SessionWorker` is started for that session.
5. The worker starts the transport and opens the local agent process.
6. The agent returns `agent_session_id`.
7. `SessionRegistry` stores the route binding.
8. `InboxProjection` records a node-local session row for `/inbox`.

### 3.2 Message Submission

1. Client submits a message through HTTP `POST /sessions/:id/messages`, SessionChannel, or `Prehen.submit_message/3`.
2. `Surface.submit_message/3` looks up the worker by `gateway_session_id`.
3. The worker forwards a `session.message` frame to the agent process.
4. The agent returns `session.output.delta` or other session events.
5. The worker normalizes the event, records it, and broadcasts it on PubSub.
6. `InboxProjection` appends retained history for the current node lifetime.

### 3.3 Channel Streaming

1. Client joins `session:<gateway_session_id>`.
2. `SessionChannel` checks that the session is attached to a live worker.
3. The channel subscribes to the gateway PubSub topic.
4. Incoming gateway events are serialized and pushed as `event`.
5. Retained stopped sessions are read-only and reject new `submit` events.

### 3.4 Trace Reads

1. `Prehen.run/2` or trace-oriented callers read from `Prehen.Trace.for_session/1`.
2. The collector returns the in-memory gateway event list for that session.
3. Trace data is best-effort gateway observability, not durable recovery state.

### 3.5 Stop and Retention

1. Client stops a session through HTTP, `/inbox/sessions/:id`, or `Prehen.stop_session/1`.
2. The gateway stops the attached worker or treats an already-terminal route as an idempotent stop.
3. `SessionRegistry` retains terminal route metadata, and `InboxProjection` retains the inbox row and history for the rest of the node lifetime.
4. `/inbox` can still render session detail and retained history after stop.
5. A node restart clears those retained rows and history.

## 4. Current Constraints

- single node only
- one session maps to one local agent process
- only profiles that pass wrapper support validation are exposed to users
- no persistent session recovery
- inbox session lists and history are node-local in-memory state
- stopped sessions stay visible only until restart
- no multi-node routing
- no tool mediation through Prehen

The old runtime-era modules, structured config loader, workspace layout manager, and OpenSpec assets have been removed from the repo. New work should extend the gateway path above rather than reintroducing those layers.
