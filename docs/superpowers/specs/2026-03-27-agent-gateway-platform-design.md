# Prehen Agent Gateway Platform Design

Date: 2026-03-27
Status: Draft approved in brainstorming

## 1. Summary

Prehen will be repositioned from an Elixir-based general-purpose AI agent runtime to a general-purpose Agent Gateway platform.

The new system goal is:

- Elixir owns gateway, routing, channels, process supervision, and node-to-node coordination.
- External agents own session state, reasoning loops, tool use strategy, and execution behavior.
- Multiple Prehen nodes form a routable OTP cluster for remote scheduling, while each node manages only its own local agents.

This design deliberately rejects the previous direction of implementing a generic in-process agent runtime in Elixir.

## 2. Why This Rebuild Exists

The current codebase is centered around internal runtime modules such as:

- `Prehen.Agent.Runtime`
- `Prehen.Agent.Session`
- `Prehen.Agent.Orchestrator`
- `Prehen.Memory.*`
- `Prehen.Agent.Backends.*`

That architecture makes Elixir responsible for both control plane and execution plane. The new direction is to narrow Prehen's responsibility:

- Prehen should be excellent at supervision, routing, channels, and cluster coordination.
- Agent-specific execution should live in the external agent system best suited for it, such as Codex or pi-coding-agent.

This keeps the platform aligned with OTP strengths and avoids rebuilding a universal agent engine inside Elixir.

## 3. Product Positioning

Prehen becomes a local-first Agent Gateway platform with these properties:

- It launches and supervises local agent processes.
- It routes client sessions to explicit or automatically selected agents.
- It exposes HTTP and Phoenix Channels as first-class gateway surfaces.
- It can route work to other Prehen nodes through OTP cluster communication.
- It does not own canonical agent session state in the MVP direction.

The intended role is similar to an OpenClaw-style gateway, but generalized for multiple locally managed agents instead of being tightly coupled to one agent implementation.

## 4. Core Architectural Decisions

### 4.1 Control Plane vs Execution Plane

Prehen owns the control plane:

- gateway session creation
- routing decisions
- agent process lifecycle
- channel fanout
- node selection
- transport health
- minimal observability

External agents own the execution plane:

- session state
- conversation history
- internal memory
- task planning
- reasoning loops
- tool execution behavior
- result production

### 4.2 Session State Ownership

Canonical session state lives in the agent, not in Prehen.

Implications:

- Prehen is not the truth source for conversation recovery.
- session replay and recovery are agent capabilities, not platform guarantees.
- if a node or agent dies, the gateway can report route/session loss clearly, but it should not pretend it can reconstruct agent state.

### 4.3 Deployment and Cluster Model

The system is local-agent-first:

- each Prehen node launches and supervises agents on the same machine
- agents do not join the distributed system directly
- only Prehen nodes form the OTP cluster

Remote scheduling is therefore implemented as:

- client reaches some Prehen node
- that node chooses local or remote Prehen node
- target Prehen node launches and manages the local agent process

### 4.4 Routing Entry Mode

The gateway supports both:

- explicit agent selection by the client
- automatic agent selection by Prehen

When no agent is specified, Prehen chooses based on simple routing policy.

### 4.5 Agent Process Model

The initial runtime model is one agent process per session.

This aligns with the decision that agent-side session state is authoritative and avoids premature complexity around long-lived multiplexed agent services.

### 4.6 Tool and Workspace Access

MVP starts with direct agent access to workspace and local tools.

Prehen does not proxy tool usage in the first version. However, protocol design must leave room for a later mixed model where some tools are mediated by Prehen.

### 4.7 Event Model

Prehen defines a thin standardized envelope for gateway-level events.

Agents are free to emit richer private events within that envelope.

This creates a stable client-facing stream without forcing all agents into one identical internal model.

## 5. System Components

### 5.1 Gateway API

Provides first-class client entry points:

- HTTP for control-plane operations
- Phoenix Channels for real-time session streams

HTTP covers:

- create session
- attach to session
- send message
- query route/session status
- inspect nodes and agent availability

Channels cover:

- stream deltas
- status changes
- lifecycle events
- routing and detach notifications

### 5.2 Session Router

Maintains gateway-facing route state only:

- `gateway_session_id`
- selected agent profile
- selected node
- current `agent_session_id`
- attach/detach status

It does not interpret the agent's internal progress.

### 5.3 Agent Supervisor

Launches and monitors local session-scoped agent processes.

Responsibilities:

- process startup
- abnormal exit detection
- lifecycle cleanup
- handoff to transport adapter

### 5.4 Agent Transport Adapter

Abstracts communication with concrete agent implementations.

Responsibilities:

- start session process
- send messages and control commands
- receive agent frames/events
- detect transport failure
- normalize inbound frames into gateway envelopes

The platform depends on adapter behavior, not on a specific transport.

### 5.5 Node Registry and Cluster Router

Coordinates Prehen nodes across the OTP cluster.

Responsibilities:

- which nodes are healthy
- which nodes can run which agent profiles
- current node-level load
- route target selection

This is routing metadata, not canonical session state.

### 5.6 Event Envelope and Observability

Prehen emits standardized control-plane events such as:

- `session.created`
- `session.routed`
- `agent.started`
- `message.forwarded`
- `agent.stream.delta`
- `agent.result`
- `agent.error`
- `agent.exited`
- `route.failed`

These events power client UX and operational diagnostics.

## 6. Session Lifecycle Model

Two session identifiers are intentionally separated.

### 6.1 Gateway Session

`gateway_session_id` is the stable identifier used by clients.

Properties:

- created by Prehen
- used for HTTP and Channel addressing
- remains the client handle even if internal routing evolves later

### 6.2 Agent Session

`agent_session_id` is owned by the agent implementation.

Properties:

- returned by the agent after startup/handshake
- internal route target bound under a gateway session
- authoritative for agent-side state

### 6.3 Lifecycle Flow

1. Client creates a gateway session.
2. Router selects local or remote Prehen node.
3. Target node launches a local agent process.
4. Prehen and the agent complete protocol handshake.
5. Client attaches to `session:<gateway_session_id>` over Channels.
6. Messages are forwarded to the bound agent session.
7. Agent emits streaming events and final outputs.
8. Route remains sticky while the session is alive.

## 7. Routing and Cluster Policy

### 7.1 Routing Rules

Initial routing should remain simple:

- explicit agent selection wins
- local node preferred when possible
- capability match required
- lower-load node preferred among valid candidates

This avoids building an overfitted scheduler before the system has real load data.

### 7.2 Sticky Routing

Once a gateway session is attached to a node and agent session, subsequent messages stay on that route by default.

### 7.3 Out of Scope for V1

The following are explicitly excluded from the first architecture wave:

- cross-node session migration
- agent-to-agent distributed collaboration
- smart global scheduling heuristics
- guaranteed session reconstruction after agent/node loss

## 8. ACP-Inspired Internal Protocol Direction

Prehen should not invent a completely private model if it can align with an emerging standard.

The internal Prehen-to-agent contract should therefore be ACP-inspired:

- align object model around agent/session/message/event concepts
- preserve message part arrays and metadata-oriented extensibility
- keep transport binding separate from protocol semantics

However, the system should not attempt full ACP compliance in the MVP. The immediate use case is locally supervised agents, not generic REST-hosted agent servers.

## 9. Failure and Recovery Model

### 9.1 Platform Errors

Prehen should strongly type its own failures:

- route selection failed
- target node unavailable
- agent launch failed
- handshake failed
- transport disconnected
- session not attached

### 9.2 Agent Errors

Agent-originated failures should be wrapped and forwarded as `agent_error` class events without over-normalizing their internal meaning.

### 9.3 Recovery Guarantees

MVP guarantees should be intentionally narrow:

- Prehen may allow reattach if the agent is still alive
- Prehen does not guarantee session recovery after restart
- Prehen does not guarantee automatic migration after remote node failure
- recovery beyond attachment semantics depends on agent support

## 10. Migration Impact on Current Codebase

### 10.1 Likely to Keep and Reshape

- `PrehenWeb.*`
- `Prehen.Client.Surface`
- selected session-management concepts
- event serialization and observability pieces

### 10.2 Likely to Remove or Demote

- `Prehen.Agent.Runtime`
- `Prehen.Agent.Session`
- `Prehen.Agent.Orchestrator`
- `Prehen.Agent.Backends.*`
- platform-owned `Memory` runtime responsibilities

### 10.3 Transitional Possibilities

Some current modules may survive temporarily as compatibility facades during the rewrite, but they should not define the new architecture.

## 11. Recommended Delivery Sequence

This rebuild should be split into separate change tracks:

1. platform architecture and protocol definition
2. single-node local agent gateway MVP
3. OTP multi-node routing and remote scheduling

This sequence keeps distributed scheduling from overwhelming the first delivery.

## 12. Open Questions Deferred

The following are intentionally postponed:

- whether future tool mediation is per-agent or per-tool
- whether a persistent gateway event log is needed
- whether gateway sessions should survive agent replacement
- whether ACP/A2A compatibility becomes an external API requirement

These should be revisited only after the single-node gateway model is working.
