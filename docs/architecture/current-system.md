# Prehen Current Architecture (As-Is)

_Last updated: 2026-03-27_

This document describes the current single-node gateway architecture as implemented today.

Prehen is now a local-first Agent Gateway and control plane:

- external local agent processes own session truth and execution semantics
- one gateway session maps to one local agent process
- HTTP and Phoenix Channels are the primary client surface
- the first supported transport is `stdio + JSON Lines`
- legacy runtime session APIs are intentionally unsupported

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
    v
Prehen.Gateway.SessionWorker
    |
    +--> Prehen.Gateway.SessionRegistry
    +--> Prehen.Observability.TraceCollector
    +--> transport adapter
             |
             +--> local external agent process
```

## 2. Component Responsibilities

### 2.1 `Prehen`

- public API facade
- forwards to the gateway-backed client surface
- exposes gateway-oriented session helpers

### 2.2 `Prehen.Client.Surface`

- creates gateway sessions
- submits messages to the active session worker
- reads gateway session status
- stops gateway sessions
- exposes `run/2` as a gateway-backed CLI compatibility path
- explicitly rejects removed runtime-era APIs such as resume, replay, list, and subscribe

### 2.3 `Prehen.Gateway.Router`

- selects an agent profile
- honors explicit agent selection when provided
- otherwise picks a local profile from the registry

### 2.4 `Prehen.Gateway.SessionWorker`

- one worker per gateway session
- starts the configured transport adapter
- opens the external local agent process
- records and broadcasts normalized gateway events
- owns the attachment between `gateway_session_id` and `agent_session_id`

### 2.5 `Prehen.Gateway.SessionRegistry`

- stores route state only
- tracks `gateway_session_id`, worker pid, agent name, agent session id, and attach status
- does not own canonical session truth

### 2.6 `Prehen.Observability.TraceCollector`

- holds a small in-memory trace for gateway events
- is used for immediate trace reads in `run/2` and related flows
- does not persist session history

### 2.7 `Prehen.Agents.Transports.Stdio`

- concrete `stdio + JSON Lines` transport
- starts the agent child process
- sends and receives JSON frames
- treats `stderr` as diagnostics

### 2.8 `PrehenWeb`

- HTTP controllers create sessions, submit messages, and read session status
- `PrehenWeb.SessionChannel` subscribes to `session:<gateway_session_id>` and forwards normalized envelopes
- `PrehenWeb.EventSerializer` strips runtime-only fields and keeps the client payload JSON safe

## 3. Current Data Flow

### 3.1 Session Creation

1. Client calls `POST /sessions` or `Prehen.create_session/1`.
2. `Surface.create_session/1` asks the router for a profile.
3. `SessionWorker` is started for that session.
4. The worker starts the transport and opens the local agent process.
5. The agent returns `agent_session_id`.
6. `SessionRegistry` stores the route binding.

### 3.2 Message Submission

1. Client submits a message through HTTP or `Prehen.submit_message/3`.
2. `Surface.submit_message/3` looks up the worker by `gateway_session_id`.
3. The worker forwards a `session.message` frame to the agent process.
4. The agent returns `session.output.delta` or other session events.
5. The worker normalizes the event, records it, and broadcasts it on PubSub.

### 3.3 Channel Streaming

1. Client joins `session:<gateway_session_id>`.
2. `SessionChannel` checks that the session is attached to a live worker.
3. The channel subscribes to the gateway PubSub topic.
4. Incoming gateway events are serialized and pushed as `event`.

### 3.4 Trace Reads

1. `Prehen.run/2` or trace-oriented callers read from `Prehen.Trace.for_session/1`.
2. The collector returns the in-memory gateway event list for that session.
3. Trace data is best-effort gateway observability, not durable recovery state.

## 4. Current Constraints

- single node only
- one session maps to one local agent process
- no persistent session recovery
- no multi-node routing
- no old runtime resume/replay/list APIs
- no tool mediation through Prehen

## 5. What Is Still In The Repo

The old runtime-era modules may still exist on disk, but they are no longer part of the MVP hot path:

- `Prehen.Agent.Runtime`
- `Prehen.Agent.Session`
- `Prehen.Workspace.SessionManager`
- `Prehen.Conversation.Store`
- legacy event projection and memory paths

New work should follow the gateway path above rather than extending those modules.
