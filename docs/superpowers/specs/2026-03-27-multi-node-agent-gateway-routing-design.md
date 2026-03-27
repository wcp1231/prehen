# Prehen Multi-Node Agent Gateway Routing Design

Date: 2026-03-27
Status: Draft

## 1. Goal

Extend the implemented single-node gateway MVP into an OTP-connected multi-node routing layer.

This phase should let any Prehen node:

- select a local or remote Prehen node for a requested agent session
- launch the agent on the selected node
- keep a sticky route for the session on the entry node
- forward client messages and normalized events across nodes
- expose node health and capacity information for routing decisions

This phase does not change the fundamental architecture:

- Prehen remains a control plane and gateway
- external local agent processes remain the execution plane
- session truth remains agent-owned

## 2. Scope

### In Scope

- OTP node-to-node routing between Prehen nodes
- remote session launch on a target node
- sticky routing on the entry node
- cluster-visible node registry with health and capacity snapshots
- remote forwarding of message submission and normalized events
- node-aware session status reads
- route-aware session channel attachment

### Out of Scope

- agent session migration between nodes
- automatic failover after target node loss
- gateway restart reattach or remote session reconstruction
- platform-owned session replay or recovery
- distributed agent processes outside the Prehen cluster
- tool proxying through Prehen

## 3. Current Baseline

The current implementation already provides:

- a local agent profile registry
- `Prehen.Gateway.SessionRegistry`, which currently mixes route and worker lookup concerns
- one `SessionWorker` per session
- a `Router` that only selects a local profile
- HTTP and Phoenix Channel surfaces for session control and event streaming

The multi-node design should preserve these single-node semantics and extend them rather than replace them.

To make remote routing coherent, the current “fetch a local worker pid and call or monitor it” hot path must be split into:

- entry-node route lookup
- target-node worker lookup
- route-aware submit, status, stop, and channel join behavior

## 4. Core Design

### 4.1 Cluster Model

Only Prehen nodes join the OTP cluster.

Each node manages:

- its own local agent profiles
- its own local `SessionWorker` processes
- its own local transport adapters
- its own local workspace access for launched agents

Agents do not communicate with the cluster directly.

### 4.2 Entry Node and Target Node

The node that receives the client request is the `entry node`.

The node chosen to launch the agent is the `target node`.

These may be the same node or different nodes.

Responsibilities:

- entry node: client-facing session ID, sticky route, request forwarding, event fanout
- target node: actual `SessionWorker`, transport management, local agent process supervision

### 4.3 Entry-Node Sticky Route Ledger

`Prehen.Gateway.SessionRegistry` should evolve into the entry-node sticky route ledger.

`gateway_session_id` remains the only client-facing session identifier.

The entry node stores one route record per client-visible session:

- `gateway_session_id`
- `entry_node`
- `target_node`
- `agent_name`
- `agent_session_id`
- `mode`
- `status`

The route record must not store remote process identifiers or worker pids.

This record is routing state, not canonical session state.

### 4.4 Target-Node Local Session Index

Target-node worker lookup must be stored separately from the entry-node route ledger.

Introduce a target-node local session index keyed by `gateway_session_id`:

- `gateway_session_id`
- `worker_pid`
- `agent_name`
- `status`

This index exists only on the node actually running the worker.

The stable remote control key is `gateway_session_id` itself. The target node uses that key to resolve submit, status, and stop against its own local session index.

The target-side local session index must reject duplicate active launches for the same `gateway_session_id`.

### 4.5 Node Registry

Each node publishes a lightweight routing snapshot to the cluster.

Minimum published fields:

- `node`
- `status`
- `agent_names`
- `active_session_count`
- `session_capacity`
- `updated_at_ms`

For routing purposes, a node is considered healthy only when:

- `status == :up`
- `updated_at_ms` is inside the configured freshness TTL
- `active_session_count < session_capacity`

The registry is eventually consistent and only supports routing decisions.

It must not be treated as canonical session truth.

### 4.6 Routing Policy

Routing remains intentionally simple in this phase:

1. explicit agent selection wins
2. local node preferred when it supports the selected agent and has capacity
3. otherwise choose a healthy remote node that supports the agent
4. tie-break by lowest active session count

This design does not introduce weighted schedulers or historical performance scoring.

## 5. New Components

### 5.1 `Prehen.Gateway.NodeRegistry`

Maintains the local node snapshot and merged remote node snapshots.

Responsibilities:

- publish the local node state
- receive remote node state
- expose healthy candidate nodes for a given agent
- expire stale remote node snapshots

### 5.2 `Prehen.Gateway.ClusterRouter`

Extends routing from “pick a local profile” to “pick a target node plus profile”.

Responsibilities:

- consult `NodeRegistry`
- choose the target node
- return a routing decision containing node and agent metadata

### 5.3 `Prehen.Gateway.ClusterSession`

Owns entry-node side remote session operations.

Responsibilities:

- request remote session launch on the target node
- submit message to the remote session by `gateway_session_id`
- read remote status by `gateway_session_id`
- stop remote session by `gateway_session_id`
- monitor target-node reachability for active remote routes

This module is a gateway-to-gateway adapter, not an agent transport.

### 5.4 `Prehen.Gateway.LocalLauncher`

Provides a narrow API on the target node for route-aware worker lifecycle operations.

Responsibilities:

- validate the requested agent
- start a local `SessionWorker`
- resolve submit, status, and stop operations by `gateway_session_id`
- own the target-node local session index

This avoids letting remote nodes reach into `DynamicSupervisor` internals directly.

### 5.5 `Prehen.Gateway.ClusterEventRelay`

Provides the explicit target-side event export boundary.

Responsibilities:

- subscribe to the target node's local `session:<gateway_session_id>` topic
- forward normalized envelopes to the entry node
- stop when the worker ends or the route is terminated

`SessionWorker` remains local-worker focused. It should not own node-to-node routing behavior directly.

## 6. Session Lifecycle

### 6.1 Session Creation

1. client calls the entry node
2. entry node selects a target node via `ClusterRouter`
3. if target is local, use the current single-node path through route-aware gateway APIs
4. if target is remote, entry node requests launch through `ClusterSession`
5. target node starts a local `SessionWorker`
6. target node stores the worker in the target-node local session index
7. target node starts a `ClusterEventRelay` bound to the entry node
8. target node returns `agent_session_id` and explicit launch acknowledgment
9. entry node records the sticky route under `gateway_session_id`

The route must only be committed after a positive launch acknowledgment.

### 6.2 Message Submission

1. client submits a message to the entry node
2. entry node loads the sticky route
3. if target node is local, dispatch through `LocalLauncher`
4. if target node is remote, forward to the target node through `ClusterSession`
5. target node resolves the worker through the local session index
6. target node delivers the message to the local worker
7. local worker continues using the existing transport path

HTTP submit APIs must no longer depend on fetching a live worker pid from the entry node.

### 6.3 Session Status and Channel Attach

Both local and remote sessions should be attached from the entry node using route records, not worker pids.

That means:

- HTTP status reads consult the entry-node route ledger first
- `SessionChannel.join/3` succeeds only when a route exists and `status == :attached`
- local worker liveness is reflected into route status through gateway events
- remote worker or target-node loss is reflected through route status and routing failure events

For remote sessions, channels must rely on route events such as `session.remote.detached` and `route.failed`, not direct worker process monitoring.

### 6.4 Event Flow

1. target node receives normalized events from the local worker
2. target-side `ClusterEventRelay` forwards those normalized events to the entry node
3. entry node writes gateway observability and broadcasts over local PubSub
4. HTTP readers and session channels continue to attach only to the entry node

The client remains unaware of whether the worker is local or remote.

### 6.5 Session Stop

Stopping a session always goes through the entry node.

The entry node:

- looks up the sticky route
- stops the local worker through `LocalLauncher` if local
- requests remote stop through `ClusterSession` if remote
- clears the sticky route only after an explicit local or remote stop acknowledgment

If the target node is unreachable during stop, the route must remain with a detached or failed status so later status reads and channels can surface the failure.

## 7. Event and Observability Semantics

The normalized gateway envelope remains unchanged.

Additional routing-oriented events should be introduced:

- `session.routed`
- `session.remote.attached`
- `session.remote.detached`
- `node.unreachable`
- `route.failed`

Event payloads should include enough routing metadata for diagnostics:

- `entry_node`
- `target_node`
- `agent_name`
- `gateway_session_id`

## 8. Failure Semantics

### 8.1 Node Selection Failure

If no healthy node can run the requested agent, the entry node returns a structured gateway error such as:

- `:no_route_available`
- `{:agent_not_available, agent_name}`

### 8.2 Remote Launch Failure

If the target node is selected but launch fails, the entry node should:

- retry another candidate node only when the first node returns an explicit pre-launch refusal such as unsupported agent or no capacity
- never retry after ambiguous outcomes such as timeout, node disconnect, or unknown acknowledgment state
- return a structured gateway error for ambiguous launch outcomes

This avoids creating two live agent sessions for one `gateway_session_id`.

### 8.3 Target Node Loss After Launch

If the target node becomes unreachable after the route is active:

- the entry node marks the session route as detached or failed
- channels receive a routing failure event
- further submissions fail explicitly

This phase does not attempt automatic reconstruction.

### 8.4 Entry Node Loss

If the entry node dies, clients lose the sticky route attachment.

This phase does not attempt recovering the entry-node route ledger after restart.

## 9. Public API Expectations

The external HTTP and Phoenix Channel shape should remain stable.

The cluster behavior should be internal to the gateway except for:

- richer `/agents` or `/nodes` introspection data
- session status showing `target_node`
- routing failure events in channels

No client-side protocol split should be introduced for local versus remote sessions.

If tests or internal control-plane helpers need a forced `target_node` override, that override must be treated as internal-only and not documented as a stable public client contract.

## 10. Implementation Constraints

- prefer small gateway-facing modules over embedding cluster logic into `SessionWorker`
- keep local single-node behavior working through the same route-aware control APIs
- use OTP primitives already natural to Elixir before adding third-party clustering dependencies
- keep the route ledger thin and explicit
- avoid distributed global process names as the primary design

## 11. Testing Strategy

The next implementation plan should cover:

- node registry snapshot merge and expiry
- healthy-node evaluation from snapshots
- cluster router selection policy
- remote session launch on another OTP node
- remote channel attach against route state
- message forwarding from entry node to remote target node
- normalized event forwarding back to the entry node
- remote stop semantics
- clear failure behavior for unreachable target nodes

## 12. Success Criteria

This phase is successful when:

- a client can create a session on node A that actually runs on node B
- message submission still targets one stable `gateway_session_id`
- channels on node A stream normalized events produced on node B
- routing chooses healthy nodes with simple capacity awareness
- full single-node behavior still works when the selected target node is local
