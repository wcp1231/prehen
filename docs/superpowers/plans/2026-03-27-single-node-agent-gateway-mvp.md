# Single-Node Agent Gateway MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current in-process Elixir agent runtime hot path with a single-node gateway that launches one local external agent process per session and streams normalized events over HTTP and Phoenix Channels.

**Architecture:** Keep Prehen focused on control-plane responsibilities: session routing, process supervision, transport management, and event normalization. Move session truth and execution semantics to the external agent process via an ACP-inspired protocol subset over a transport abstraction, with `stdio + JSON Lines` as the first concrete adapter.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, OTP supervision, JSON Lines over stdio, ExUnit

---

## Scope Check

This plan intentionally covers only the single-node MVP from:

- `docs/superpowers/specs/2026-03-27-agent-gateway-platform-design.md`
- `docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md`

Do not mix OTP multi-node routing into this implementation plan. Treat cluster routing as the next plan after the single-node gateway is stable and tested.

## File Structure

### New files

- `lib/prehen/gateway/supervisor.ex`
  Root supervisor for gateway-only runtime children.
- `lib/prehen/gateway/session_registry.ex`
  Owns `gateway_session_id -> route/process/attach` metadata.
- `lib/prehen/gateway/router.ex`
  Picks a local agent profile when the client does not specify one.
- `lib/prehen/gateway/session_worker.ex`
  One process per gateway session; owns transport adapter instance and event sequencing.
- `lib/prehen/agents/profile.ex`
  Struct for local agent launch configuration.
- `lib/prehen/agents/registry.ex`
  Loads and exposes configured local agent profiles.
- `lib/prehen/agents/transport.ex`
  Behaviour for process-backed agent transports.
- `lib/prehen/agents/transports/stdio.ex`
  Concrete `stdio + JSON Lines` adapter.
- `lib/prehen/agents/protocol/frame.ex`
  ACP-inspired internal frame helpers for `session.open`, `session.message`, `session.control`, and normalized replies.
- `lib/prehen/agents/envelope.ex`
  Stable client-facing gateway envelope builder.
- `test/prehen/gateway/session_registry_test.exs`
  Registry semantics tests.
- `test/prehen/gateway/session_worker_test.exs`
  Session worker lifecycle and event normalization tests.
- `test/prehen/agents/transports/stdio_test.exs`
  Transport adapter tests against a fake agent.
- `test/prehen_web/channels/session_channel_test.exs`
  Channel streaming tests for the new gateway envelopes.
- `test/support/fake_stdio_agent.exs`
  Deterministic fake agent process used by transport and integration tests.

### Files to modify

- `lib/prehen/application.ex`
  Replace old agent-runtime children on the hot path with gateway supervisors and registries.
- `lib/prehen.ex`
  Keep public API stable while routing to gateway-backed surface functions.
- `lib/prehen/client/surface.ex`
  Rewrite from runtime facade to gateway facade.
- `lib/prehen/config.ex`
  Add loading/validation for local agent profiles and gateway runtime options.
- `lib/prehen_web/controllers/session_controller.ex`
  Create sessions, submit messages, and read gateway session status.
- `lib/prehen_web/controllers/agent_controller.ex`
  Report configured local agent profiles instead of old internal agent templates.
- `lib/prehen_web/channels/session_channel.ex`
  Attach to gateway session workers and stream normalized gateway envelopes.
- `lib/prehen_web/serializers/event_serializer.ex`
  Serialize the new envelope shape instead of old ledger/runtime records.
- `lib/prehen_web/router.ex`
  Ensure the minimal MVP HTTP surface exists and routes to the gateway controllers.
- `test/prehen/client/surface_test.exs`
  Rewrite around gateway semantics.
- `test/prehen/cli_test.exs`
  Keep CLI expectations aligned with gateway-backed `run/2` compatibility, or explicitly narrow CLI scope if removed from MVP.
- `test/prehen/integration/platform_runtime_test.exs`
  Replace runtime-oriented integration assertions with gateway flow assertions.

### Files likely to delete or remove from the hot path later

- `lib/prehen/agent/runtime.ex`
- `lib/prehen/agent/session.ex`
- `lib/prehen/agent/orchestrator.ex`
- `lib/prehen/agent/backends/*`
- `test/prehen/agent/runtime_test.exs`
- `test/prehen/agent/session_test.exs`
- `test/prehen/agent/orchestrator_test.exs`

Do not delete these files in the first commit unless the replacement path is already green. First make the gateway path real, then remove dead runtime code in a later cleanup task.

## Task 1: Lock the MVP Contract in Tests

**Files:**
- Create: `test/prehen/gateway/session_registry_test.exs`
- Create: `test/prehen/gateway/session_worker_test.exs`
- Create: `test/prehen/agents/transports/stdio_test.exs`
- Create: `test/prehen_web/channels/session_channel_test.exs`
- Create: `test/support/fake_stdio_agent.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Write the failing transport handshake test**

```elixir
defmodule Prehen.Agents.Transports.StdioTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Transports.Stdio
  alias Prehen.Agents.Profile

  test "opens a session and returns the agent_session_id from the child process" do
    profile = %Profile{
      name: "fake_stdio",
      command: ["elixir", "test/support/fake_stdio_agent.exs"]
    }

    assert {:ok, transport} = Stdio.start_link(profile: profile, gateway_session_id: "gw_1")
    assert {:ok, %{agent_session_id: "agent_gw_1"}} = Stdio.open_session(transport, %{})
  end
end
```

- [ ] **Step 2: Run the transport test to verify it fails**

Run: `mix test test/prehen/agents/transports/stdio_test.exs`

Expected: FAIL with `Prehen.Agents.Transports.Stdio` undefined or missing functions.

- [ ] **Step 3: Write the failing session worker event test**

```elixir
defmodule Prehen.Gateway.SessionWorkerTest do
  use ExUnit.Case, async: false

  alias Prehen.Gateway.SessionWorker

  test "forwards normalized output delta events with gateway session metadata" do
    assert {:ok, pid} =
             SessionWorker.start_link(
               gateway_session_id: "gw_1",
               agent_name: "fake_stdio",
               test_pid: self()
             )

    assert :ok = SessionWorker.submit_message(pid, %{role: "user", parts: [%{type: "text", text: "hi"}]})

    assert_receive {:gateway_event, %{type: "session.output.delta", gateway_session_id: "gw_1"}}
  end
end
```

- [ ] **Step 4: Run the worker test to verify it fails**

Run: `mix test test/prehen/gateway/session_worker_test.exs`

Expected: FAIL with missing `SessionWorker` implementation.

- [ ] **Step 5: Write the failing channel attach test**

```elixir
defmodule PrehenWeb.SessionChannelTest do
  use PrehenWeb.ChannelCase, async: false

  test "pushes normalized gateway envelopes to subscribers" do
    {:ok, _, socket} =
      socket(PrehenWeb.UserSocket)
      |> subscribe_and_join(PrehenWeb.SessionChannel, "session:gw_1")

    assert_push "event", %{"type" => "session.output.delta", "gateway_session_id" => "gw_1"}
  end
end
```

- [ ] **Step 6: Run the channel test to verify it fails**

Run: `mix test test/prehen_web/channels/session_channel_test.exs`

Expected: FAIL because the new gateway session attach path is not implemented yet.

- [ ] **Step 7: Commit the contract tests**

```bash
git add test/test_helper.exs test/support/fake_stdio_agent.exs test/prehen/gateway/session_registry_test.exs test/prehen/gateway/session_worker_test.exs test/prehen/agents/transports/stdio_test.exs test/prehen_web/channels/session_channel_test.exs
git commit -m "test: lock single-node gateway mvp contract"
```

## Task 2: Introduce Agent Profiles and Gateway-Only Runtime Children

**Files:**
- Create: `lib/prehen/agents/profile.ex`
- Create: `lib/prehen/agents/registry.ex`
- Create: `lib/prehen/gateway/supervisor.ex`
- Create: `lib/prehen/gateway/router.ex`
- Modify: `lib/prehen/application.ex`
- Modify: `lib/prehen/config.ex`
- Test: `test/prehen/tools/pack_registry_test.exs`
- Test: `test/prehen/client/surface_test.exs`

- [ ] **Step 1: Write a failing config/registry test**

```elixir
test "loads local agent profiles for gateway routing" do
  config = Prehen.Config.load(agent_profiles: [fake_stdio: [command: ["elixir", "fake.exs"]]])

  assert [%Prehen.Agents.Profile{name: "fake_stdio"}] = config.agent_profiles
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/prehen/client/surface_test.exs`

Expected: FAIL because `agent_profiles` are not part of the config contract.

- [ ] **Step 3: Implement the minimal profile and registry modules**

```elixir
defmodule Prehen.Agents.Profile do
  @enforce_keys [:name, :command]
  defstruct [:name, :command, args: [], env: %{}, transport: :stdio, metadata: %{}]
end
```

```elixir
defmodule Prehen.Agents.Registry do
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def all, do: GenServer.call(__MODULE__, :all)
  def fetch!(name), do: GenServer.call(__MODULE__, {:fetch!, name})
end
```

- [ ] **Step 4: Rewire the application supervision tree for the gateway path**

Run: `mix test test/prehen/client/surface_test.exs`

Expected: PASS for the new config/registry assertions and no boot-time crashes from `Prehen.Application`.

- [ ] **Step 5: Commit the gateway runtime skeleton**

```bash
git add lib/prehen/agents/profile.ex lib/prehen/agents/registry.ex lib/prehen/gateway/supervisor.ex lib/prehen/gateway/router.ex lib/prehen/application.ex lib/prehen/config.ex test/prehen/client/surface_test.exs
git commit -m "feat: add gateway profile registry skeleton"
```

## Task 3: Build the ACP-Inspired Frame Helpers and Stdio Transport

**Files:**
- Create: `lib/prehen/agents/transport.ex`
- Create: `lib/prehen/agents/transports/stdio.ex`
- Create: `lib/prehen/agents/protocol/frame.ex`
- Modify: `test/support/fake_stdio_agent.exs`
- Test: `test/prehen/agents/transports/stdio_test.exs`

- [ ] **Step 1: Write a failing frame encoding test**

```elixir
test "builds a session.open frame with gateway metadata" do
  frame =
    Prehen.Agents.Protocol.Frame.session_open(
      gateway_session_id: "gw_1",
      agent: "fake_stdio",
      workspace: "/tmp/demo"
    )

  assert frame.type == "session.open"
  assert frame.payload.gateway_session_id == "gw_1"
end
```

- [ ] **Step 2: Run the frame/transport tests to verify they fail**

Run: `mix test test/prehen/agents/transports/stdio_test.exs`

Expected: FAIL because the protocol helper and adapter do not exist yet.

- [ ] **Step 3: Implement the minimal frame helper and transport behaviour**

```elixir
defmodule Prehen.Agents.Transport do
  @callback open_session(pid(), map()) :: {:ok, map()} | {:error, term()}
  @callback send_message(pid(), map()) :: :ok | {:error, term()}
  @callback send_control(pid(), map()) :: :ok | {:error, term()}
  @callback stop(pid()) :: :ok
end
```

- [ ] **Step 4: Implement the stdio adapter until the fake agent handshake test passes**

Run: `mix test test/prehen/agents/transports/stdio_test.exs`

Expected: PASS, including:
- `session.open` is written to stdin
- `session.opened` is parsed from stdout
- `stderr` diagnostics do not crash the transport

- [ ] **Step 5: Commit the first real transport**

```bash
git add lib/prehen/agents/transport.ex lib/prehen/agents/transports/stdio.ex lib/prehen/agents/protocol/frame.ex test/support/fake_stdio_agent.exs test/prehen/agents/transports/stdio_test.exs
git commit -m "feat: add stdio transport for local agents"
```

## Task 4: Implement the Gateway Session Registry and Session Worker

**Files:**
- Create: `lib/prehen/gateway/session_registry.ex`
- Create: `lib/prehen/gateway/session_worker.ex`
- Create: `lib/prehen/agents/envelope.ex`
- Modify: `lib/prehen/gateway/supervisor.ex`
- Modify: `test/prehen/gateway/session_registry_test.exs`
- Modify: `test/prehen/gateway/session_worker_test.exs`

- [ ] **Step 1: Write a failing registry test for create/attach/lookup**

```elixir
test "stores route metadata for a gateway session" do
  assert :ok =
           Prehen.Gateway.SessionRegistry.put(%{
             gateway_session_id: "gw_1",
             agent_name: "fake_stdio",
             agent_session_id: "agent_gw_1",
             status: :attached
           })

  assert {:ok, %{agent_session_id: "agent_gw_1"}} =
           Prehen.Gateway.SessionRegistry.fetch("gw_1")
end
```

- [ ] **Step 2: Run the registry and worker tests to verify they fail**

Run: `mix test test/prehen/gateway/session_registry_test.exs test/prehen/gateway/session_worker_test.exs`

Expected: FAIL because registry semantics and event sequencing are not implemented.

- [ ] **Step 3: Implement the registry and stable envelope builder**

```elixir
defmodule Prehen.Agents.Envelope do
  def build(type, attrs) do
    %{
      type: type,
      gateway_session_id: attrs.gateway_session_id,
      agent_session_id: attrs.agent_session_id,
      agent: attrs.agent,
      node: Atom.to_string(node()),
      seq: attrs.seq,
      timestamp: System.system_time(:millisecond),
      payload: attrs.payload || %{},
      metadata: attrs.metadata || %{}
    }
  end
end
```

- [ ] **Step 4: Implement the session worker around one transport instance**

Run: `mix test test/prehen/gateway/session_registry_test.exs test/prehen/gateway/session_worker_test.exs`

Expected: PASS, including:
- session worker starts the transport
- handshake stores `agent_session_id`
- outbound messages become `session.message` frames
- inbound frames become normalized gateway events

- [ ] **Step 5: Commit the gateway worker path**

```bash
git add lib/prehen/gateway/session_registry.ex lib/prehen/gateway/session_worker.ex lib/prehen/agents/envelope.ex lib/prehen/gateway/supervisor.ex test/prehen/gateway/session_registry_test.exs test/prehen/gateway/session_worker_test.exs
git commit -m "feat: add session worker for gateway-managed agents"
```

## Task 5: Rewrite Client Surface and HTTP Controllers Around the Gateway

**Files:**
- Modify: `lib/prehen.ex`
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen_web/controllers/session_controller.ex`
- Modify: `lib/prehen_web/controllers/agent_controller.ex`
- Modify: `lib/prehen_web/router.ex`
- Test: `test/prehen/client/surface_test.exs`
- Test: `test/prehen/integration/platform_runtime_test.exs`

- [ ] **Step 1: Write a failing surface test for create/send/status**

```elixir
test "create_session starts a gateway session and returns gateway metadata" do
  assert {:ok, %{session_id: gateway_session_id}} =
           Prehen.Client.Surface.create_session(agent: "fake_stdio")

  assert is_binary(gateway_session_id)
end
```

- [ ] **Step 2: Run the surface and integration tests to verify they fail**

Run: `mix test test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs`

Expected: FAIL because the surface still targets `Prehen.Agent.Runtime`.

- [ ] **Step 3: Rewrite the surface to talk to `SessionRegistry`, `Router`, and `SessionWorker`**

```elixir
def create_session(opts \\ []) do
  with {:ok, profile} <- Prehen.Gateway.Router.select_agent(opts),
       {:ok, session} <- Prehen.Gateway.SessionWorker.start_session(profile, opts) do
    {:ok, %{session_id: session.gateway_session_id, agent: profile.name}}
  end
end
```

- [ ] **Step 4: Rewrite the HTTP controllers and routes to expose the MVP control plane**

Run: `mix test test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs`

Expected: PASS, including:
- `POST /sessions` returns gateway session metadata
- `POST /sessions/:id/messages` forwards user messages
- `GET /agents` lists local agent profiles

- [ ] **Step 5: Commit the gateway surface cutover**

```bash
git add lib/prehen.ex lib/prehen/client/surface.ex lib/prehen_web/controllers/session_controller.ex lib/prehen_web/controllers/agent_controller.ex lib/prehen_web/router.ex test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs
git commit -m "feat: route client surface through gateway sessions"
```

## Task 6: Rebuild the Phoenix Session Channel and Event Serializer

**Files:**
- Modify: `lib/prehen_web/channels/session_channel.ex`
- Modify: `lib/prehen_web/channels/user_socket.ex`
- Modify: `lib/prehen_web/serializers/event_serializer.ex`
- Test: `test/prehen_web/channels/session_channel_test.exs`
- Test: `test/prehen_web/serializers/event_serializer_test.exs`

- [ ] **Step 1: Write a failing serializer test for the new envelope**

```elixir
test "serializes the gateway envelope without runtime-specific fields" do
  event =
    Prehen.Agents.Envelope.build("session.output.delta", %{
      gateway_session_id: "gw_1",
      agent_session_id: "agent_gw_1",
      agent: "fake_stdio",
      seq: 1,
      payload: %{"text" => "hel"}
    })

  assert %{"type" => "session.output.delta", "gateway_session_id" => "gw_1"} =
           PrehenWeb.EventSerializer.serialize(event)
end
```

- [ ] **Step 2: Run serializer and channel tests to verify they fail**

Run: `mix test test/prehen_web/serializers/event_serializer_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: FAIL because serializer/channel still assume old replayed runtime records.

- [ ] **Step 3: Rewrite the session channel to subscribe to live gateway events**

```elixir
def handle_info({:gateway_event, event}, socket) do
  push(socket, "event", EventSerializer.serialize(event))
  {:noreply, socket}
end
```

- [ ] **Step 4: Make serializer and channel tests pass**

Run: `mix test test/prehen_web/serializers/event_serializer_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS, including live stream events and clean attach errors when the gateway session does not exist.

- [ ] **Step 5: Commit the streaming surface**

```bash
git add lib/prehen_web/channels/session_channel.ex lib/prehen_web/channels/user_socket.ex lib/prehen_web/serializers/event_serializer.ex test/prehen_web/serializers/event_serializer_test.exs test/prehen_web/channels/session_channel_test.exs
git commit -m "feat: stream gateway envelopes over phoenix channels"
```

## Task 7: Remove the Old Runtime from the MVP Path and Tighten Observability

**Files:**
- Modify: `lib/prehen/application.ex`
- Modify: `lib/prehen/trace.ex`
- Modify: `lib/prehen/observability/trace_collector.ex`
- Modify: `test/prehen/cli_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Delete or stop referencing: `test/prehen/agent/runtime_test.exs`
- Delete or stop referencing: `test/prehen/agent/session_test.exs`

- [ ] **Step 1: Write a failing integration test for gateway-owned observability**

```elixir
test "records gateway lifecycle events for a session run" do
  assert {:ok, %{session_id: gateway_session_id}} = Prehen.Client.Surface.create_session(agent: "fake_stdio")
  assert {:ok, events} = Prehen.Trace.for_session(gateway_session_id)
  assert Enum.any?(events, &(&1.type == "agent.started"))
end
```

- [ ] **Step 2: Run the integration and CLI tests to verify they fail**

Run: `mix test test/prehen/cli_test.exs test/prehen/integration/platform_runtime_test.exs`

Expected: FAIL because trace and CLI still assume old runtime semantics.

- [ ] **Step 3: Remove the old runtime from the app boot path and narrow observability to gateway lifecycle events**

```elixir
children = [
  {Phoenix.PubSub, name: Prehen.PubSub},
  {Prehen.Agents.Registry, []},
  {Prehen.Gateway.Supervisor, []},
  PrehenWeb.Endpoint
]
```

- [ ] **Step 4: Make the end-to-end gateway tests pass**

Run: `mix test test/prehen/agents/transports/stdio_test.exs test/prehen/gateway/session_registry_test.exs test/prehen/gateway/session_worker_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/serializers/event_serializer_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS for the full single-node gateway MVP path.

- [ ] **Step 5: Commit the MVP cutover**

```bash
git add lib/prehen/application.ex lib/prehen/trace.ex lib/prehen/observability/trace_collector.ex test/prehen/cli_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/agent/runtime_test.exs test/prehen/agent/session_test.exs
git commit -m "refactor: cut over to single-node agent gateway mvp"
```

## Task 8: Cleanup, Docs, and Exit Criteria

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`
- Modify: `docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md`
- Test: entire MVP suite

- [ ] **Step 1: Update README and architecture docs to describe the new gateway-first direction**

```md
- Prehen is now a local-first Agent Gateway.
- External agents own session truth and execution behavior.
- The first supported transport is stdio JSON Lines.
```

- [ ] **Step 2: Run the focused MVP suite**

Run: `mix test test/prehen/agents/transports/stdio_test.exs test/prehen/gateway/session_registry_test.exs test/prehen/gateway/session_worker_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen_web/serializers/event_serializer_test.exs test/prehen_web/channels/session_channel_test.exs`

Expected: PASS

- [ ] **Step 3: Run the full test suite**

Run: `mix test`

Expected: PASS, or a short explicit allowlist of intentionally removed old-runtime tests that must be deleted in the same branch.

- [ ] **Step 4: Commit the docs and cleanup**

```bash
git add README.md docs/architecture/current-system.md docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md
git commit -m "docs: describe single-node gateway architecture"
```

## Implementation Notes

- Prefer introducing new gateway namespaces before deleting old runtime namespaces.
- Keep adapters small; do not let `Stdio` absorb routing or session registry logic.
- Preserve the public API shape where possible, but change semantics to gateway semantics.
- Avoid adding persistent session recovery in this plan. That is explicitly out of scope.
- Avoid introducing cluster logic in this branch. Leave extension seams only.

## Plan Review Notes

If you want formal plan review, run a dedicated plan-document reviewer against:

- `docs/superpowers/plans/2026-03-27-single-node-agent-gateway-mvp.md`
- `docs/superpowers/specs/2026-03-27-agent-gateway-platform-design.md`
- `docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md`

This session did not auto-dispatch a reviewer.
