# Multi-Node Agent Gateway Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the single-node gateway MVP so an entry Prehen node can route sessions to a healthy remote Prehen node and keep sticky client routing across the cluster.

**Architecture:** Keep agent execution local to the target node and move only gateway routing across nodes. Introduce a cluster-visible node registry, a cluster router that picks a target node, and a thin remote-session adapter that lets the entry node create, message, and stop a worker running on another Prehen node.

**Tech Stack:** Elixir 1.19, OTP distribution, Phoenix 1.8, ExUnit, stdio JSON Lines transport, RPC / node messaging

---

## Scope Check

This plan intentionally covers only:

- remote node selection
- remote session launch
- sticky route ledger on the entry node
- node health and capacity snapshots
- remote message and event forwarding

It does not cover:

- session migration
- post-crash reattach
- automatic failover
- tool proxying

## File Structure

### New files

- `lib/prehen/gateway/node_registry.ex`
  Cluster-visible node snapshot registry with TTL/expiry.
- `lib/prehen/gateway/cluster_router.ex`
  Selects the target node for a requested agent.
- `lib/prehen/gateway/cluster_session.ex`
  Entry-node side remote session adapter for create/message/stop.
- `lib/prehen/gateway/local_launcher.ex`
  Target-node API for launching and managing local workers on behalf of other nodes.
- `test/prehen/gateway/node_registry_test.exs`
  Covers snapshot publish, merge, fetch, and expiry.
- `test/prehen/gateway/cluster_router_test.exs`
  Covers routing policy and capacity-aware selection.
- `test/prehen/gateway/cluster_session_test.exs`
  Covers remote launch, submit, stop, and remote event forwarding.
- `test/support/cluster_test_node.exs`
  Boots a lightweight slave node for remote gateway integration tests.

### Files to modify

- `lib/prehen/application.ex`
  Health reporting for node-registry and cluster routing.
- `lib/prehen/gateway/supervisor.ex`
  Start node-registry and cluster session support processes.
- `lib/prehen/gateway/router.ex`
  Split local-only route logic from cluster-aware route decisions.
- `lib/prehen/gateway/session_registry.ex`
  Expand route records to store `entry_node`, `target_node`, remote worker handle, and status.
- `lib/prehen/gateway/session_worker.ex`
  Emit route-aware events without absorbing cluster routing logic.
- `lib/prehen/client/surface.ex`
  Create, submit, status, and stop through the cluster-aware routing path.
- `lib/prehen_web/controllers/session_controller.ex`
  Return node-aware session status.
- `lib/prehen_web/controllers/agent_controller.ex`
  Optionally expose cluster-visible availability data.
- `lib/prehen_web/channels/session_channel.ex`
  Continue streaming entry-node events for remote sessions.
- `test/prehen/client/surface_test.exs`
  Add remote-route coverage.
- `test/prehen/integration/platform_runtime_test.exs`
  Add entry-node to remote-node integration assertions.

### Files likely to get follow-up cleanup later

- `lib/prehen/gateway/router.ex`
  May become a thin compatibility wrapper around `ClusterRouter`.
- `lib/prehen/gateway/session_registry.ex`
  May later split into local route state and cluster route ledger.

## Task 1: Lock the Multi-Node Routing Contract in Tests

**Files:**
- Create: `test/prehen/gateway/node_registry_test.exs`
- Create: `test/prehen/gateway/cluster_router_test.exs`
- Create: `test/prehen/gateway/cluster_session_test.exs`
- Create: `test/support/cluster_test_node.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`

- [ ] **Step 1: Write the failing node-registry test**

```elixir
defmodule Prehen.Gateway.NodeRegistryTest do
  use ExUnit.Case, async: false

  alias Prehen.Gateway.NodeRegistry

  test "stores local snapshot and merges a remote snapshot" do
    :ok =
      NodeRegistry.put_local_snapshot(%{
        node: node(),
        status: :up,
        agent_names: ["fake_stdio"],
        active_session_count: 1,
        session_capacity: 4
      })

    :ok =
      NodeRegistry.merge_remote_snapshot(%{
        node: :"remote@127.0.0.1",
        status: :up,
        agent_names: ["fake_stdio", "alt_agent"],
        active_session_count: 0,
        session_capacity: 4,
        updated_at_ms: System.system_time(:millisecond)
      })

    assert {:ok, local} = NodeRegistry.fetch(node())
    assert local.agent_names == ["fake_stdio"]

    assert {:ok, remote} = NodeRegistry.fetch(:"remote@127.0.0.1")
    assert "alt_agent" in remote.agent_names
  end
end
```

- [ ] **Step 2: Run the node-registry test to verify it fails**

Run: `mix test test/prehen/gateway/node_registry_test.exs`

Expected: FAIL because `Prehen.Gateway.NodeRegistry` does not exist yet.

- [ ] **Step 3: Write the failing cluster-router test**

```elixir
defmodule Prehen.Gateway.ClusterRouterTest do
  use ExUnit.Case, async: false

  alias Prehen.Gateway.ClusterRouter
  alias Prehen.Gateway.NodeRegistry

  test "prefers the local node when it supports the agent and has capacity" do
    :ok =
      NodeRegistry.put_local_snapshot(%{
        node: node(),
        status: :up,
        agent_names: ["fake_stdio"],
        active_session_count: 0,
        session_capacity: 2
      })

    assert {:ok, %{target_node: target_node, agent: "fake_stdio"}} =
             ClusterRouter.route(agent: "fake_stdio")

    assert target_node == node()
  end
end
```

- [ ] **Step 4: Run the cluster-router test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_router_test.exs`

Expected: FAIL because cluster-aware route selection is not implemented yet.

- [ ] **Step 5: Write the failing remote-session integration test**

```elixir
defmodule Prehen.Gateway.ClusterSessionTest do
  use ExUnit.Case, async: false

  alias Prehen.Client.Surface

  test "entry node can route a session to a remote node and receive output locally" do
    {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(agent: "fake_stdio", target_node: remote_node)

    assert {:ok, %{status: :accepted}} = Surface.submit_message(session_id, "hello")

    assert_receive {:gateway_event, %{type: "session.output.delta"}}, 2_000
  end
end
```

- [ ] **Step 6: Run the remote-session test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_session_test.exs`

Expected: FAIL because remote launch and cross-node forwarding are not implemented.

- [ ] **Step 7: Commit the routing contract tests**

```bash
git add test/prehen/gateway/node_registry_test.exs test/prehen/gateway/cluster_router_test.exs test/prehen/gateway/cluster_session_test.exs test/support/cluster_test_node.exs test/prehen/integration/platform_runtime_test.exs
git commit -m "test: lock multi-node gateway routing contract"
```

## Task 2: Introduce the Cluster Node Registry

**Files:**
- Create: `lib/prehen/gateway/node_registry.ex`
- Modify: `lib/prehen/gateway/supervisor.ex`
- Modify: `lib/prehen/application.ex`
- Test: `test/prehen/gateway/node_registry_test.exs`

- [ ] **Step 1: Write the failing local-snapshot implementation test**

Add to `test/prehen/gateway/node_registry_test.exs`:

```elixir
test "expires stale remote snapshots" do
  now = System.system_time(:millisecond)

  :ok =
    NodeRegistry.merge_remote_snapshot(%{
      node: :"stale@127.0.0.1",
      status: :up,
      agent_names: ["fake_stdio"],
      active_session_count: 1,
      session_capacity: 4,
      updated_at_ms: now - 120_000
    })

  NodeRegistry.expire_stale(now_ms: now, ttl_ms: 60_000)

  assert {:error, :not_found} = NodeRegistry.fetch(:"stale@127.0.0.1")
end
```

- [ ] **Step 2: Run the node-registry test to verify it fails**

Run: `mix test test/prehen/gateway/node_registry_test.exs`

Expected: FAIL because expiry and snapshot storage are missing.

- [ ] **Step 3: Implement the registry module and wire it into the supervisor**

```elixir
defmodule Prehen.Gateway.NodeRegistry do
  use GenServer

  def put_local_snapshot(snapshot), do: GenServer.call(__MODULE__, {:put_local, snapshot})
  def merge_remote_snapshot(snapshot), do: GenServer.call(__MODULE__, {:merge_remote, snapshot})
  def fetch(node_name), do: GenServer.call(__MODULE__, {:fetch, node_name})
  def all, do: GenServer.call(__MODULE__, :all)
  def expire_stale(opts \\ []), do: GenServer.call(__MODULE__, {:expire_stale, opts})
end
```

- [ ] **Step 4: Update application health to report node-registry status**

Run: `mix test test/prehen/gateway/node_registry_test.exs`

Expected: PASS

- [ ] **Step 5: Commit the node-registry skeleton**

```bash
git add lib/prehen/gateway/node_registry.ex lib/prehen/gateway/supervisor.ex lib/prehen/application.ex test/prehen/gateway/node_registry_test.exs
git commit -m "feat: add cluster node registry"
```

## Task 3: Add Cluster-Aware Route Selection

**Files:**
- Create: `lib/prehen/gateway/cluster_router.ex`
- Modify: `lib/prehen/gateway/router.ex`
- Modify: `lib/prehen/gateway/session_registry.ex`
- Test: `test/prehen/gateway/cluster_router_test.exs`

- [ ] **Step 1: Write the failing remote-selection test**

Add to `test/prehen/gateway/cluster_router_test.exs`:

```elixir
test "falls back to a healthy remote node when local capacity is exhausted" do
  :ok =
    NodeRegistry.put_local_snapshot(%{
      node: node(),
      status: :up,
      agent_names: ["fake_stdio"],
      active_session_count: 2,
      session_capacity: 2
    })

  :ok =
    NodeRegistry.merge_remote_snapshot(%{
      node: :"remote@127.0.0.1",
      status: :up,
      agent_names: ["fake_stdio"],
      active_session_count: 0,
      session_capacity: 2,
      updated_at_ms: System.system_time(:millisecond)
    })

  assert {:ok, %{target_node: :"remote@127.0.0.1"}} =
           ClusterRouter.route(agent: "fake_stdio")
end
```

- [ ] **Step 2: Run the router test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_router_test.exs`

Expected: FAIL because remote fallback is missing.

- [ ] **Step 3: Implement cluster-aware selection and expand route records**

`SessionRegistry.put/1` should start storing:

```elixir
%{
  gateway_session_id: gateway_session_id,
  entry_node: node(),
  target_node: target_node,
  agent_name: agent_name,
  agent_session_id: agent_session_id,
  worker_pid: worker_pid,
  remote_ref: remote_ref,
  status: :attached
}
```

- [ ] **Step 4: Keep the old local route path working through the new router**

Run: `mix test test/prehen/gateway/cluster_router_test.exs test/prehen/gateway/session_registry_test.exs`

Expected: PASS

- [ ] **Step 5: Commit cluster routing policy**

```bash
git add lib/prehen/gateway/cluster_router.ex lib/prehen/gateway/router.ex lib/prehen/gateway/session_registry.ex test/prehen/gateway/cluster_router_test.exs test/prehen/gateway/session_registry_test.exs
git commit -m "feat: add cluster-aware node selection"
```

## Task 4: Add Target-Node Local Launch and Remote Session Control

**Files:**
- Create: `lib/prehen/gateway/local_launcher.ex`
- Create: `lib/prehen/gateway/cluster_session.ex`
- Modify: `lib/prehen/gateway/session_worker.ex`
- Modify: `lib/prehen/client/surface.ex`
- Test: `test/prehen/gateway/cluster_session_test.exs`

- [ ] **Step 1: Write the failing remote-launch test**

Add to `test/prehen/gateway/cluster_session_test.exs`:

```elixir
test "launch_remote starts a worker on the target node and returns route metadata" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{target_node: ^remote_node, agent_session_id: agent_session_id}} =
           Prehen.Gateway.ClusterSession.launch_remote(remote_node,
             gateway_session_id: "gw_remote_1",
             agent: "fake_stdio"
           )

  assert is_binary(agent_session_id)
end
```

- [ ] **Step 2: Run the remote-launch test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_session_test.exs`

Expected: FAIL because the remote launcher path does not exist yet.

- [ ] **Step 3: Implement the target-node launcher and entry-node remote adapter**

The target-node launcher API should look like:

```elixir
def launch(opts) do
  with {:ok, profile} <- Prehen.Gateway.Router.route(agent: opts[:agent]),
       {:ok, session} <- Prehen.Gateway.SessionWorker.start_session(profile, opts) do
    {:ok, %{worker_pid: session.worker_pid, gateway_session_id: session.gateway_session_id}}
  end
end
```

The entry-node adapter should hide the RPC details from `Surface`.

- [ ] **Step 4: Re-run the remote-session tests**

Run: `mix test test/prehen/gateway/cluster_session_test.exs`

Expected: PASS for remote launch and stop basics.

- [ ] **Step 5: Commit the remote session-control path**

```bash
git add lib/prehen/gateway/local_launcher.ex lib/prehen/gateway/cluster_session.ex lib/prehen/gateway/session_worker.ex lib/prehen/client/surface.ex test/prehen/gateway/cluster_session_test.exs
git commit -m "feat: add remote session control across gateway nodes"
```

## Task 5: Forward Remote Events Back to the Entry Node

**Files:**
- Modify: `lib/prehen/gateway/cluster_session.ex`
- Modify: `lib/prehen/gateway/session_worker.ex`
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen_web/channels/session_channel.ex`
- Test: `test/prehen/gateway/cluster_session_test.exs`
- Test: `test/prehen/integration/platform_runtime_test.exs`

- [ ] **Step 1: Write the failing remote-event-forwarding test**

Add to `test/prehen/gateway/cluster_session_test.exs`:

```elixir
test "remote worker events are rebroadcast on the entry node topic" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{session_id: session_id}} =
           Prehen.Client.Surface.create_session(agent: "fake_stdio", target_node: remote_node)

  :ok = Phoenix.PubSub.subscribe(Prehen.PubSub, "session:#{session_id}")

  assert {:ok, %{status: :accepted}} =
           Prehen.Client.Surface.submit_message(session_id, "hello remote")

  assert_receive {:gateway_event, %{type: "session.output.delta", gateway_session_id: ^session_id}}
end
```

- [ ] **Step 2: Run the forwarding test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_session_test.exs`

Expected: FAIL because remote events are not rebroadcast on the entry node.

- [ ] **Step 3: Forward normalized events instead of raw transport frames**

The target node should forward already-normalized gateway envelopes.

The entry node should:

- persist observability
- rebroadcast over local PubSub
- keep the existing channel contract unchanged

- [ ] **Step 4: Re-run the remote forwarding and integration tests**

Run: `mix test test/prehen/gateway/cluster_session_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS

- [ ] **Step 5: Commit remote event forwarding**

```bash
git add lib/prehen/gateway/cluster_session.ex lib/prehen/gateway/session_worker.ex lib/prehen/client/surface.ex lib/prehen_web/channels/session_channel.ex test/prehen/gateway/cluster_session_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs
git commit -m "feat: forward remote gateway events on entry nodes"
```

## Task 6: Surface Node-Aware Status and Failure Semantics

**Files:**
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen_web/controllers/session_controller.ex`
- Modify: `lib/prehen_web/controllers/agent_controller.ex`
- Modify: `lib/prehen_web/serializers/event_serializer.ex`
- Test: `test/prehen/client/surface_test.exs`
- Test: `test/prehen/integration/platform_runtime_test.exs`

- [ ] **Step 1: Write the failing status test**

Add to `test/prehen/client/surface_test.exs`:

```elixir
test "session_status includes target_node for remote sessions" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{session_id: session_id}} =
           Surface.create_session(agent: "fake_stdio", target_node: remote_node)

  assert {:ok, status} = Surface.session_status(session_id)
  assert status.target_node == remote_node
  assert status.entry_node == node()
end
```

- [ ] **Step 2: Run the status test to verify it fails**

Run: `mix test test/prehen/client/surface_test.exs`

Expected: FAIL because session status does not include node-aware route metadata.

- [ ] **Step 3: Add node-aware status fields and routing failure errors**

Expected failure shapes:

```elixir
{:error, %{type: :submit_failed, reason: :target_node_unreachable}}
{:error, %{type: :session_status_failed, reason: :not_found}}
```

- [ ] **Step 4: Re-run the HTTP/controller tests**

Run: `mix test test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs`

Expected: PASS

- [ ] **Step 5: Commit node-aware status reporting**

```bash
git add lib/prehen/client/surface.ex lib/prehen_web/controllers/session_controller.ex lib/prehen_web/controllers/agent_controller.ex lib/prehen_web/serializers/event_serializer.ex test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs
git commit -m "feat: expose node-aware gateway session status"
```

## Task 7: Final Verification and Documentation Touch-Up

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`
- Modify: `docs/superpowers/specs/2026-03-27-multi-node-agent-gateway-routing-design.md`
- Test: full routing suite and full `mix test`

- [ ] **Step 1: Update docs to describe remote-node routing**

Add concise notes covering:

- entry node versus target node
- cluster node registry
- sticky route ledger
- what still is not supported

- [ ] **Step 2: Run the focused routing suite**

Run: `mix test test/prehen/gateway/node_registry_test.exs test/prehen/gateway/cluster_router_test.exs test/prehen/gateway/cluster_session_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS

- [ ] **Step 3: Run the full test suite**

Run: `mix test`

Expected: PASS

- [ ] **Step 4: Commit docs and final cleanup**

```bash
git add README.md docs/architecture/current-system.md docs/superpowers/specs/2026-03-27-multi-node-agent-gateway-routing-design.md
git commit -m "docs: describe multi-node gateway routing"
```

## Implementation Notes

- Prefer RPC or explicit node messaging over distributed global process names.
- Keep remote session handling out of `SessionWorker`; it should stay local-worker focused.
- Do not hide routing state inside process dictionaries or opaque tuples.
- Preserve the current single-node path as a valid fast path.
- Avoid introducing persistent cluster metadata storage in this phase.

## Plan Review Notes

If you want formal plan review, run a plan reviewer against:

- `docs/superpowers/plans/2026-03-27-multi-node-agent-gateway-routing.md`
- `docs/superpowers/specs/2026-03-27-multi-node-agent-gateway-routing-design.md`
