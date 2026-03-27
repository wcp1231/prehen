# Multi-Node Agent Gateway Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the single-node gateway MVP so an entry Prehen node can route sessions to a healthy remote Prehen node and keep sticky client routing across the cluster.

**Architecture:** Keep agent execution local to the target node and move only gateway routing across nodes. Split entry-node route state from target-node worker lookup, add a cluster-visible node registry, and introduce explicit remote session control and event relay modules keyed by `gateway_session_id`.

**Tech Stack:** Elixir 1.19, OTP distribution, Phoenix 1.8, ExUnit, stdio JSON Lines transport, RPC / node messaging

---

## Scope Check

This plan intentionally covers only:

- remote node selection
- remote session launch
- sticky route ledger on the entry node
- target-node local worker lookup
- node health and capacity snapshots
- remote message and event forwarding
- route-aware channel attach and failure signaling

It does not cover:

- session migration
- post-crash reattach
- automatic failover
- tool proxying

## File Structure

### New files

- `lib/prehen/gateway/node_registry.ex`
  Cluster-visible node snapshot registry with TTL and health evaluation.
- `lib/prehen/gateway/cluster_router.ex`
  Selects the target node for a requested agent.
- `lib/prehen/gateway/local_session_index.ex`
  Target-node worker lookup keyed by `gateway_session_id`.
- `lib/prehen/gateway/cluster_session.ex`
  Entry-node side remote session adapter for create, submit, status, and stop.
- `lib/prehen/gateway/local_launcher.ex`
  Target-node API for launching and managing local workers by `gateway_session_id`.
- `lib/prehen/gateway/cluster_event_relay.ex`
  Target-side relay that forwards normalized envelopes back to the entry node.
- `test/prehen/gateway/node_registry_test.exs`
  Covers snapshot publish, merge, fetch, expiry, and healthy-node evaluation.
- `test/prehen/gateway/cluster_router_test.exs`
  Covers routing policy and capacity-aware selection.
- `test/prehen/gateway/cluster_session_test.exs`
  Covers remote launch, submit, status, stop, and remote event forwarding.
- `test/support/cluster_test_node.exs`
  Boots a lightweight slave node for remote gateway integration tests.

### Files to modify

- `lib/prehen/application.ex`
  Health reporting for node-registry and cluster routing.
- `lib/prehen/gateway/supervisor.ex`
  Start node-registry, local-session-index, and cluster support processes.
- `lib/prehen/gateway/router.ex`
  Reduce to a compatibility layer around cluster-aware routing.
- `lib/prehen/gateway/session_registry.ex`
  Evolve into an entry-node sticky route ledger only.
- `lib/prehen/gateway/session_worker.ex`
  Stay local-worker focused while publishing normalized events for relay.
- `lib/prehen/client/surface.ex`
  Create, submit, status, and stop through the route-aware cluster path.
- `lib/prehen_web/controllers/session_controller.ex`
  Return node-aware session status and route failure semantics.
- `lib/prehen_web/controllers/agent_controller.ex`
  Expose cluster-visible availability data if kept in scope.
- `lib/prehen_web/channels/session_channel.ex`
  Attach against route state instead of requiring a local worker pid.
- `lib/prehen_web/serializers/event_serializer.ex`
  Preserve route-oriented event fields for remote sessions.
- `test/prehen/client/surface_test.exs`
  Add remote-route coverage.
- `test/prehen/integration/platform_runtime_test.exs`
  Add entry-node to remote-node integration assertions.
- `test/prehen_web/channels/session_channel_test.exs`
  Add remote route attach and failure-event coverage.

### Files likely to get follow-up cleanup later

- `lib/prehen/gateway/router.ex`
  May later collapse into `ClusterRouter`.
- `lib/prehen_web/controllers/agent_controller.ex`
  May later split `/agents` and `/nodes` introspection if the response grows.

## Task 1: Lock the Multi-Node Routing Contract in Tests

**Files:**
- Create: `test/prehen/gateway/node_registry_test.exs`
- Create: `test/prehen/gateway/cluster_router_test.exs`
- Create: `test/prehen/gateway/cluster_session_test.exs`
- Create: `test/support/cluster_test_node.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen_web/channels/session_channel_test.exs`

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

- [ ] **Step 3: Write the failing remote-session integration test**

```elixir
defmodule Prehen.Gateway.ClusterSessionTest do
  use ExUnit.Case, async: false

  alias Prehen.Client.Surface

  test "entry node can route a session to a remote node and receive output locally" do
    {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()
    :ok = Phoenix.PubSub.subscribe(Prehen.PubSub, "session:gw_remote_test")

    assert {:ok, %{session_id: session_id}} =
             Surface.create_session(
               agent: "fake_stdio",
               gateway_session_id: "gw_remote_test",
               test_target_node: remote_node
             )

    assert {:ok, %{status: :accepted}} = Surface.submit_message(session_id, "hello")

    assert_receive {:gateway_event, %{type: "session.output.delta", gateway_session_id: ^session_id}},
                   2_000
  end
end
```

- [ ] **Step 4: Run the remote-session test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_session_test.exs`

Expected: FAIL because remote launch and cross-node forwarding are not implemented.

- [ ] **Step 5: Write the failing remote channel attach test**

Add to `test/prehen_web/channels/session_channel_test.exs`:

```elixir
test "joins a remote-routed session from the entry node and receives route failure events" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{session_id: session_id}} =
           Prehen.Client.Surface.create_session(
             agent: "fake_stdio",
             gateway_session_id: "gw_channel_remote",
             test_target_node: remote_node
           )

  assert {:ok, _, socket} =
           socket(PrehenWeb.UserSocket)
           |> subscribe_and_join(PrehenWeb.SessionChannel, "session:#{session_id}")

  push(socket, "simulate_route_failure", %{})
  assert_push "event", %{"type" => "route.failed", "session_id" => ^session_id}
end
```

- [ ] **Step 6: Run the channel test to verify it fails**

Run: `mix test test/prehen_web/channels/session_channel_test.exs`

Expected: FAIL because channel join still depends on local worker-pid lookup and has no remote failure signaling.

- [ ] **Step 7: Do not commit yet**

Carry these failing tests into Task 2 so the first multi-node routing commit can stay green.

## Task 2: Separate Entry-Node Route State from Target-Node Worker Lookup

**Files:**
- Create: `lib/prehen/gateway/local_session_index.ex`
- Create: `lib/prehen/gateway/local_launcher.ex`
- Modify: `lib/prehen/gateway/session_registry.ex`
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen_web/channels/session_channel.ex`
- Test: `test/prehen/client/surface_test.exs`
- Test: `test/prehen_web/channels/session_channel_test.exs`
- Test: `test/prehen/gateway/cluster_session_test.exs`

- [ ] **Step 1: Write the failing route-ledger test**

Add to `test/prehen/client/surface_test.exs`:

```elixir
test "session_status resolves through route records instead of local worker pid lookup" do
  assert {:ok, %{session_id: session_id}} =
           Surface.create_session(agent: "fake_stdio")

  assert {:ok, status} = Surface.session_status(session_id)
  assert status.entry_node == node()
  assert status.target_node == node()
end
```

- [ ] **Step 2: Run the route-ledger test to verify it fails**

Run: `mix test test/prehen/client/surface_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: FAIL because current status and channel join still depend on local worker state.

- [ ] **Step 3: Introduce `LocalSessionIndex` and narrow `SessionRegistry` to route state**

```elixir
defmodule Prehen.Gateway.LocalSessionIndex do
  use GenServer

  def put(gateway_session_id, worker_pid), do: GenServer.call(__MODULE__, {:put, gateway_session_id, worker_pid})
  def fetch(gateway_session_id), do: GenServer.call(__MODULE__, {:fetch, gateway_session_id})
  def delete(gateway_session_id), do: GenServer.call(__MODULE__, {:delete, gateway_session_id})
end
```

Route records should use a stable shape:

```elixir
%{
  gateway_session_id: gateway_session_id,
  entry_node: entry_node,
  target_node: target_node,
  agent_name: agent_name,
  agent_session_id: agent_session_id,
  mode: :local | :remote,
  status: :attached | :detached | :failed
}
```

- [ ] **Step 4: Change `SessionChannel.join/3` to attach by route existence, not local worker pid**

Run: `mix test test/prehen/client/surface_test.exs test/prehen_web/channels/session_channel_test.exs test/prehen/gateway/cluster_session_test.exs`

Expected: PASS

- [ ] **Step 5: Commit the route-state split and green contract tests**

```bash
git add lib/prehen/gateway/local_session_index.ex lib/prehen/gateway/local_launcher.ex lib/prehen/gateway/session_registry.ex lib/prehen/client/surface.ex lib/prehen_web/channels/session_channel.ex test/prehen/client/surface_test.exs test/prehen_web/channels/session_channel_test.exs test/prehen/gateway/cluster_session_test.exs
git commit -m "refactor: split route ledger from local worker index"
```

## Task 3: Introduce the Cluster Node Registry

**Files:**
- Create: `lib/prehen/gateway/node_registry.ex`
- Modify: `lib/prehen/gateway/supervisor.ex`
- Modify: `lib/prehen/application.ex`
- Modify: `lib/prehen/gateway/local_launcher.ex`
- Test: `test/prehen/gateway/node_registry_test.exs`

- [ ] **Step 1: Write the failing local-publication test**

Add to `test/prehen/gateway/node_registry_test.exs`:

```elixir
test "publishes local health based on active sessions and configured capacity" do
  assert {:ok, snapshot} = NodeRegistry.fetch(node())
  assert snapshot.status == :up
  assert is_integer(snapshot.active_session_count)
  assert is_integer(snapshot.session_capacity)
end
```

- [ ] **Step 2: Run the node-registry test to verify it fails**

Run: `mix test test/prehen/gateway/node_registry_test.exs`

Expected: FAIL because local snapshot publication is not implemented.

- [ ] **Step 3: Implement the registry module and wire local snapshot publication**

`LocalLauncher` should publish local session-count changes into `NodeRegistry` when workers start and stop.

- [ ] **Step 4: Add expiry and healthy-node evaluation coverage**

Run: `mix test test/prehen/gateway/node_registry_test.exs`

Expected: PASS

- [ ] **Step 5: Commit the node-registry skeleton**

```bash
git add lib/prehen/gateway/node_registry.ex lib/prehen/gateway/supervisor.ex lib/prehen/application.ex lib/prehen/gateway/local_launcher.ex test/prehen/gateway/node_registry_test.exs
git commit -m "feat: add cluster node registry"
```

## Task 4: Add Cluster-Aware Route Selection

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

- [ ] **Step 3: Implement cluster-aware selection**

`ClusterRouter.route/1` should return:

```elixir
%{
  entry_node: node(),
  target_node: chosen_node,
  agent_name: "fake_stdio",
  mode: if(chosen_node == node(), do: :local, else: :remote)
}
```

The `test_target_node` override used in tests must remain internal control-plane plumbing, not a public client API contract.

- [ ] **Step 4: Re-run the router tests**

Run: `mix test test/prehen/gateway/cluster_router_test.exs test/prehen/gateway/session_registry_test.exs`

Expected: PASS

- [ ] **Step 5: Commit cluster routing policy**

```bash
git add lib/prehen/gateway/cluster_router.ex lib/prehen/gateway/router.ex lib/prehen/gateway/session_registry.ex test/prehen/gateway/cluster_router_test.exs test/prehen/gateway/session_registry_test.exs
git commit -m "feat: add cluster-aware node selection"
```

## Task 5: Add Target-Node Launch, Submit, Status, and Stop by Gateway Session Id

**Files:**
- Create: `lib/prehen/gateway/cluster_session.ex`
- Modify: `lib/prehen/gateway/local_launcher.ex`
- Modify: `lib/prehen/client/surface.ex`
- Test: `test/prehen/gateway/cluster_session_test.exs`
- Test: `test/prehen/client/surface_test.exs`

- [ ] **Step 1: Write the failing remote-launch and remote-stop tests**

Add to `test/prehen/gateway/cluster_session_test.exs`:

```elixir
test "launch_remote starts a worker on the target node and stop_remote stops it by gateway_session_id" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{target_node: ^remote_node, agent_session_id: agent_session_id}} =
           Prehen.Gateway.ClusterSession.launch_remote(remote_node,
             gateway_session_id: "gw_remote_1",
             agent: "fake_stdio"
           )

  assert is_binary(agent_session_id)
  assert :ok = Prehen.Gateway.ClusterSession.stop_remote(remote_node, "gw_remote_1")
end
```

- [ ] **Step 2: Add the failing ambiguous-launch test**

```elixir
test "ambiguous remote launch outcome does not retry another node" do
  {:ok, flaky_node} = Prehen.TestSupport.ClusterTestNode.start_link(mode: :timeout_on_launch)

  assert {:error, :remote_launch_outcome_unknown} =
           Prehen.Client.Surface.create_session(
             agent: "fake_stdio",
             gateway_session_id: "gw_no_retry",
             test_target_node: flaky_node
           )
end
```

- [ ] **Step 3: Run the remote-session test to verify it fails**

Run: `mix test test/prehen/gateway/cluster_session_test.exs`

Expected: FAIL because remote control by `gateway_session_id` does not exist yet.

- [ ] **Step 4: Implement the target-node launcher and entry-node remote adapter**

The target-node launcher API should be keyed by `gateway_session_id`, not worker refs:

```elixir
def launch(opts), do: {:ok, %{gateway_session_id: opts[:gateway_session_id], agent_session_id: "..."}}
def submit(gateway_session_id, attrs), do: :ok
def status(gateway_session_id), do: {:ok, %{status: :attached}}
def stop(gateway_session_id), do: :ok
```

Only explicit pre-launch refusals may fall through to another candidate. Unknown outcomes must fail closed.

- [ ] **Step 5: Re-run the remote control tests**

Run: `mix test test/prehen/gateway/cluster_session_test.exs test/prehen/client/surface_test.exs`

Expected: PASS

- [ ] **Step 6: Commit the remote session-control path**

```bash
git add lib/prehen/gateway/cluster_session.ex lib/prehen/gateway/local_launcher.ex lib/prehen/client/surface.ex test/prehen/gateway/cluster_session_test.exs test/prehen/client/surface_test.exs
git commit -m "feat: add remote session control across gateway nodes"
```

## Task 6: Forward Remote Events Back to the Entry Node

**Files:**
- Create: `lib/prehen/gateway/cluster_event_relay.ex`
- Modify: `lib/prehen/gateway/cluster_session.ex`
- Modify: `lib/prehen/gateway/session_worker.ex`
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen_web/channels/session_channel.ex`
- Test: `test/prehen/gateway/cluster_session_test.exs`
- Test: `test/prehen/integration/platform_runtime_test.exs`
- Test: `test/prehen_web/channels/session_channel_test.exs`

- [ ] **Step 1: Write the failing remote-event-forwarding test**

Add to `test/prehen/gateway/cluster_session_test.exs`:

```elixir
test "remote worker events are rebroadcast on the entry node topic" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{session_id: session_id}} =
           Prehen.Client.Surface.create_session(
             agent: "fake_stdio",
             gateway_session_id: "gw_remote_forward",
             test_target_node: remote_node
           )

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

`ClusterEventRelay` should own the target-side subscription and forwarding. `SessionWorker` should continue emitting normalized local events only.

The entry node should:

- persist observability
- rebroadcast over local PubSub
- keep the existing channel contract unchanged
- emit route failure events when the target node disconnects

- [ ] **Step 4: Re-run the remote forwarding and integration tests**

Run: `mix test test/prehen/gateway/cluster_session_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS

- [ ] **Step 5: Commit remote event forwarding**

```bash
git add lib/prehen/gateway/cluster_event_relay.ex lib/prehen/gateway/cluster_session.ex lib/prehen/gateway/session_worker.ex lib/prehen/client/surface.ex lib/prehen_web/channels/session_channel.ex test/prehen/gateway/cluster_session_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs
git commit -m "feat: forward remote gateway events on entry nodes"
```

## Task 7: Surface Node-Aware Status and Failure Semantics

**Files:**
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen_web/controllers/session_controller.ex`
- Modify: `lib/prehen_web/controllers/agent_controller.ex`
- Modify: `lib/prehen_web/serializers/event_serializer.ex`
- Test: `test/prehen/client/surface_test.exs`
- Test: `test/prehen/integration/platform_runtime_test.exs`
- Test: `test/prehen_web/channels/session_channel_test.exs`

- [ ] **Step 1: Write the failing status test**

Add to `test/prehen/client/surface_test.exs`:

```elixir
test "session_status includes target_node for remote sessions" do
  {:ok, remote_node} = Prehen.TestSupport.ClusterTestNode.start_link()

  assert {:ok, %{session_id: session_id}} =
           Surface.create_session(
             agent: "fake_stdio",
             test_target_node: remote_node
           )

  assert {:ok, status} = Surface.session_status(session_id)
  assert status.target_node == remote_node
  assert status.entry_node == node()
end
```

- [ ] **Step 2: Run the status test to verify it fails**

Run: `mix test test/prehen/client/surface_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: FAIL because session status does not include node-aware route metadata.

- [ ] **Step 3: Add node-aware status fields and routing failure errors**

Expected failure shapes:

```elixir
{:error, %{type: :session_create_failed, reason: :no_route_available}}
{:error, %{type: :session_create_failed, reason: :remote_launch_outcome_unknown}}
{:error, %{type: :submit_failed, reason: :target_node_unreachable}}
{:error, %{type: :session_status_failed, reason: :not_found}}
```

Add channel coverage for:

```elixir
assert_push "event", %{"type" => "route.failed", "session_id" => session_id}
```

- [ ] **Step 4: Re-run the HTTP, controller, and channel tests**

Run: `mix test test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS

- [ ] **Step 5: Commit node-aware status reporting**

```bash
git add lib/prehen/client/surface.ex lib/prehen_web/controllers/session_controller.ex lib/prehen_web/controllers/agent_controller.ex lib/prehen_web/serializers/event_serializer.ex test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/channels/session_channel_test.exs
git commit -m "feat: expose node-aware gateway session status"
```

## Task 8: Final Verification and Documentation Touch-Up

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`
- Modify: `docs/superpowers/specs/2026-03-27-multi-node-agent-gateway-routing-design.md`
- Test: full routing suite and full `mix test`

- [ ] **Step 1: Update docs to describe remote-node routing**

Add concise notes covering:

- entry node versus target node
- cluster node registry
- split between route ledger and local session index
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
