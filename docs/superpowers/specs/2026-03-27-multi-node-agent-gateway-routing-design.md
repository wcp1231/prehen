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
- node-aware agent listing and routing decisions

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
- a local session registry
- one `SessionWorker` per session
- a `Router` that only selects a local profile
- HTTP and Phoenix Channel surfaces for session control and event streaming

The multi-node design should preserve these single-node semantics and extend them rather than replace them.

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

### 4.3 Sticky Route Ledger

`gateway_session_id` remains the only client-facing session identifier.

The entry node stores a sticky route record that maps the gateway session to:

- `gateway_session_id`
- `entry_node`
- `target_node`
- `agent_name`
- `agent_session_id`
- `target_worker_ref`
- `status`

This record is routing state, not canonical session state.

### 4.4 Node Registry

Each node publishes a lightweight routing snapshot to the cluster.

Minimum published fields:

- `node`
- `status`
- `agent_names`
- `active_session_count`
- `session_capacity`
- `updated_at_ms`

The registry is eventually consistent and only supports routing decisions.

It must not be treated as canonical session truth.

### 4.5 Routing Policy

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
- submit message to the remote worker through OTP messaging or RPC
- stop remote session on the target node
- subscribe to remote normalized events and rebroadcast them locally

This module is a gateway-to-gateway adapter, not an agent transport.

### 5.4 `Prehen.Gateway.LocalLauncher`

Provides a narrow API on the target node for remote launch requests.

Responsibilities:

- validate the requested agent
- start a local `SessionWorker`
- return the remote session handle and `agent_session_id`

This avoids letting remote nodes reach into `DynamicSupervisor` or `SessionRegistry` details directly.

## 6. Session Lifecycle

### 6.1 Session Creation

1. client calls the entry node
2. entry node selects a target node via `ClusterRouter`
3. if target is local, use the current single-node path
4. if target is remote, entry node requests launch through `ClusterSession`
5. target node starts a local `SessionWorker`
6. target node returns `agent_session_id` and worker handle
7. entry node records the sticky route under `gateway_session_id`

### 6.2 Message Submission

1. client submits a message to the entry node
2. entry node loads the sticky route
3. if target node is local, call the local worker
4. if target node is remote, forward to the target node through `ClusterSession`
5. target node delivers the message to the local worker
6. target worker continues using the existing transport path

### 6.3 Event Flow

1. target node receives normalized events from the local worker
2. target node forwards those normalized events to the entry node
3. entry node writes gateway observability and broadcasts over local PubSub
4. HTTP readers and session channels continue to attach only to the entry node

The client remains unaware of whether the worker is local or remote.

### 6.4 Session Stop

Stopping a session always goes through the entry node.

The entry node:

- looks up the sticky route
- stops the local worker if local
- requests remote stop if remote
- clears the sticky route after the stop is acknowledged or the remote node is unreachable

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
- `agent`
- `gateway_session_id`

## 8. Failure Semantics

### 8.1 Node Selection Failure

If no healthy node can run the requested agent, the entry node returns a structured gateway error such as:

- `:no_route_available`
- `{:agent_not_available, agent_name}`

### 8.2 Remote Launch Failure

If the target node is selected but launch fails, the entry node should:

- try another healthy node only if launch has not yet succeeded anywhere
- otherwise return `:remote_launch_failed`

This retry must happen before a sticky route is committed.

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

## 10. Implementation Constraints

- prefer small gateway-facing modules over embedding cluster logic into `SessionWorker`
- keep local single-node behavior working unchanged
- use OTP primitives already natural to Elixir before adding third-party clustering dependencies
- keep the route ledger thin and explicit
- avoid distributed global process names as the primary design

## 11. Testing Strategy

The next implementation plan should cover:

- node registry snapshot merge and expiry
- cluster router selection policy
- remote session launch on another OTP node
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
