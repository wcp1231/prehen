# Pi Native Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current passthrough-based `pi` path with a real `PiCodingAgent` wrapper that consumes `pi --mode json` directly while preserving existing Gateway HTTP, Channel, CLI, and inbox flows.

**Architecture:** Keep `SessionWorker` and the public Gateway surface unchanged at the wrapper boundary. Rewrite `PiCodingAgent` into a GenServer-owned state machine that opens a synthetic session locally, launches `pi` per submitted turn via `ExecutableHost`, parses native JSON lines, and emits normalized `session.output.*` frames. Remove `Passthrough` and `Stdio` from the MVP runtime and test path once the `pi` wrapper is proven.

**Tech Stack:** Elixir 1.19, OTP GenServer, Phoenix 1.8, ExUnit, external process hosting through `ExecutableHost`, Python test fixtures for deterministic JSON-stream simulation

---

## Scope Check

This plan intentionally covers only the `pi`-native wrapper refactor from [2026-04-02-pi-native-wrapper-design.md](/Users/wenchunpeng/Hack/elixir/prehen/docs/superpowers/specs/2026-04-02-pi-native-wrapper-design.md):

- rewrite `PiCodingAgent` around `pi --mode json`
- preserve the current wrapper behaviour shape used by `SessionWorker`
- support one in-flight turn per session
- rewire high-level tests to use a fake `pi` JSON-stream executable
- remove now-dead `Passthrough` and `Stdio` code

It does not cover:

- MCP or Prehen-managed tool bridging
- persistent session recovery
- multi-node routing
- a generic wrapper abstraction for other coding agents

## File Structure

### New files

- `test/support/fake_pi_json_agent.py`
  Deterministic fake executable that emits `pi --mode json`-like JSON lines for unit and integration tests.
- `test/support/pi_agent_fixture.ex`
  Shared test fixture helpers for `Profile`, `Implementation`, and registry state pointing at the fake `pi` executable.

### Files to modify

- `lib/prehen/agents/wrappers/pi_coding_agent.ex`
  Rewrite from `Passthrough` adapter to native `pi` wrapper state machine.
- `lib/mix/tasks/prehen.server.ex`
  Remove temporary debug instrumentation added during investigation.
- `test/prehen/agents/wrappers/pi_coding_agent_test.exs`
  Replace passthrough-style contract tests with native `pi` wrapper tests.
- `test/test_helper.exs`
  Load shared support fixtures if needed.
- `test/prehen_test.exs`
  Route the top-level API tests through the shared fake `pi` fixture.
- `test/prehen/cli_test.exs`
  Route CLI coverage through the shared fake `pi` fixture.
- `test/prehen/client/surface_test.exs`
  Swap passthrough-backed fake implementations for `PiCodingAgent`-backed fixtures.
- `test/prehen/integration/platform_runtime_test.exs`
  Use `PiCodingAgent` fixture for `/agents`, session create, and message flow.
- `test/prehen/integration/web_inbox_test.exs`
  Use `PiCodingAgent` fixture for inbox create and stream flow.
- `test/prehen_web/channels/session_channel_test.exs`
  Use `PiCodingAgent` fixture for channel submit and event assertions.
- `README.md`
  Document `pi`-native startup and smoke flow.
- `docs/architecture/current-system.md`
  Update the current-system snapshot to remove `Stdio` from the active path.

### Files to delete

- `lib/prehen/agents/wrappers/passthrough.ex`
- `lib/prehen/agents/transports/stdio.ex`
- `test/prehen/agents/wrappers/passthrough_test.exs`
- `test/prehen/agents/transports/stdio_test.exs`
- `test/support/fake_wrapper_agent.exs`
- `test/support/fake_stdio_agent.exs`

### Deliberate decomposition choices

- Keep `ExecutableHost` as the only generic process-hosting primitive. Do not introduce a second transport layer during this refactor.
- Keep the wrapper state machine in `pi_coding_agent.ex` for the MVP. Do not split it into extra files until the behaviour is proven.
- Add one shared test fixture module so the conversion from `fake_stdio` to `fake_pi` does not duplicate implementation maps across five test files.

## Task 1: Rewrite `PiCodingAgent` Around the Native Pi Event Stream

**Files:**
- Create: `test/support/fake_pi_json_agent.py`
- Modify: `test/prehen/agents/wrappers/pi_coding_agent_test.exs`
- Modify: `lib/prehen/agents/wrappers/pi_coding_agent.ex`

- [ ] **Step 1: Write the failing native-wrapper tests**

Add a deterministic fake `pi` executable and rewrite the focused wrapper test to assert the new semantics:

```python
# test/support/fake_pi_json_agent.py
#!/usr/bin/env python3

import json
import os
import sys
import time


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    mode = os.environ.get("FAKE_PI_MODE", "happy")
    prompt = " ".join(sys.argv[1:])

    if mode == "invalid_header":
        emit({"type": "not_session"})
        return

    emit({"type": "session", "version": 3, "id": "fake_pi_session", "cwd": os.getcwd()})
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})

    if mode == "busy":
        time.sleep(1.5)

    emit(
        {
            "type": "message_update",
            "message": {"role": "assistant", "content": []},
            "assistantMessageEvent": {"type": "text_delta", "delta": f"echo:{prompt}"},
        }
    )
    emit({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": f"echo:{prompt}"}]}})
    emit({"type": "turn_end", "message": {"role": "assistant", "content": [{"type": "text", "text": f"echo:{prompt}"}]}, "toolResults": []})
    emit({"type": "agent_end", "messages": [{"role": "assistant", "content": [{"type": "text", "text": f"echo:{prompt}"}]}]})


if __name__ == "__main__":
    main()
```

```elixir
# test/prehen/agents/wrappers/pi_coding_agent_test.exs
test "opens a synthetic session and maps pi text deltas into gateway frames" do
  session_config = session_config(tmp_workspace_path("native"), implementation: fake_pi_implementation())

  assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)

  assert {:ok, %{agent_session_id: agent_session_id}} =
           PiCodingAgent.open_session(wrapper, %{
             gateway_session_id: "gw_pi_native",
             provider: "openai",
             model: "gpt-5",
             prompt_profile: "coder_default",
             workspace: session_config.workspace
           })

  assert is_binary(agent_session_id)

  assert :ok =
           PiCodingAgent.send_message(wrapper, %{
             agent_session_id: agent_session_id,
             message_id: "msg_pi_native",
             parts: [%{type: "text", text: "ping"}]
           })

  assert {:ok, %{"type" => "session.output.delta", "payload" => %{"message_id" => "msg_pi_native", "text" => "echo:ping"}}} =
           PiCodingAgent.recv_event(wrapper, 1_000)

  assert {:ok, %{"type" => "session.output.completed", "payload" => %{"message_id" => "msg_pi_native"}}} =
           PiCodingAgent.recv_event(wrapper, 1_000)
end

test "rejects a second turn while a run is still active" do
  session_config =
    session_config(tmp_workspace_path("busy"), implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "busy"}))

  assert {:ok, wrapper} = PiCodingAgent.start_link(session_config: session_config)
  assert {:ok, %{agent_session_id: agent_session_id}} =
           PiCodingAgent.open_session(wrapper, %{gateway_session_id: "gw_busy"})

  assert :ok =
           PiCodingAgent.send_message(wrapper, %{
             agent_session_id: agent_session_id,
             message_id: "msg_busy_1",
             parts: [%{type: "text", text: "first"}]
           })

  assert {:error, :session_busy} =
           PiCodingAgent.send_message(wrapper, %{
             agent_session_id: agent_session_id,
             message_id: "msg_busy_2",
             parts: [%{type: "text", text: "second"}]
           })
end

test "support_check rejects a stream without a valid session header" do
  session_config =
    session_config(
      tmp_workspace_path("invalid_header"),
      implementation: fake_pi_implementation(%{"FAKE_PI_MODE" => "invalid_header"})
    )

  assert {:error, :contract_failed} = PiCodingAgent.support_check(session_config)
end
```

- [ ] **Step 2: Run the focused wrapper tests to verify they fail on the current passthrough implementation**

Run:

```bash
mix test test/prehen/agents/wrappers/pi_coding_agent_test.exs
```

Expected:

```text
FAIL
```

with failures showing that the current implementation is still waiting for `session.opened` or delegating into `Passthrough`.

- [ ] **Step 3: Replace the passthrough adapter with a real wrapper state machine**

Rewrite `lib/prehen/agents/wrappers/pi_coding_agent.ex` so it owns session state, launches `pi` on `send_message/2`, and parses native stdout events from `ExecutableHost`.

```elixir
defmodule Prehen.Agents.Wrappers.PiCodingAgent do
  use GenServer

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.PromptContext
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrapper
  alias Prehen.Agents.Wrappers.ExecutableHost
  alias Prehen.Config

  @behaviour Wrapper
  @recv_call_slack_ms 300
  @rejected_workspace_policy_modes ~w(disabled off unmanaged)

  @impl Wrapper
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl Wrapper
  def open_session(wrapper, attrs), do: GenServer.call(wrapper, {:open_session, attrs})

  @impl Wrapper
  def send_message(wrapper, attrs), do: GenServer.call(wrapper, {:send_message, attrs})

  @impl Wrapper
  def send_control(wrapper, attrs), do: GenServer.call(wrapper, {:send_control, attrs})

  @impl Wrapper
  def recv_event(wrapper, timeout \\ 5_000),
    do: GenServer.call(wrapper, {:recv_event, timeout}, timeout + @recv_call_slack_ms)

  @impl Wrapper
  def stop(wrapper), do: GenServer.stop(wrapper)

  @impl Wrapper
  def support_check(%SessionConfig{} = session_config) do
    with {:ok, launch} <- build_launch_spec(session_config, "__support_check__", "health check"),
         :ok <- ensure_workspace(launch.cwd),
         {:ok, host} <- ExecutableHost.start_link(owner: self(), command: launch.command, args: launch.args, env: launch.env),
         {:ok, :valid} <- await_support_stream(host) do
      ExecutableHost.stop(host)
      :ok
    else
      {:error, reason} -> classify_preflight_error(reason)
    end
  end

  @impl true
  def init(opts) do
    session_config = Keyword.fetch!(opts, :session_config)

    {:ok,
     %{
       session_config: session_config,
       gateway_session_id: nil,
       agent_session_id: nil,
       status: :idle,
       current_run: nil,
       pending_events: :queue.new(),
       recv_from: nil,
       recv_timer_ref: nil,
       current_message_id: nil,
       buffer: ""
     }}
  end

  @impl true
  def handle_call({:open_session, attrs}, _from, %{agent_session_id: nil} = state) do
    gateway_session_id = fetch_required_string!(attrs, :gateway_session_id)
    agent_session_id = "pi_" <> Integer.to_string(System.unique_integer([:positive]))

    {:reply, {:ok, %{agent_session_id: agent_session_id}},
     %{state | gateway_session_id: gateway_session_id, agent_session_id: agent_session_id, status: :idle}}
  end

  def handle_call({:open_session, _attrs}, _from, state), do: {:reply, {:error, :session_already_open}, state}

  def handle_call({:send_message, _attrs}, _from, %{agent_session_id: nil} = state),
    do: {:reply, {:error, :session_not_open}, state}

  def handle_call({:send_message, _attrs}, _from, %{status: :running} = state),
    do: {:reply, {:error, :session_busy}, state}

  def handle_call({:send_message, attrs}, _from, state) do
    text = extract_user_text(Map.get(attrs, :parts, []))
    message_id = Map.fetch!(attrs, :message_id)

    with {:ok, launch} <- build_launch_spec(state.session_config, message_id, text),
         {:ok, host} <- ExecutableHost.start_link(owner: self(), command: launch.command, args: launch.args, env: launch.env) do
      {:reply, :ok, %{state | status: :running, current_run: host, current_message_id: message_id, buffer: ""}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_control, _attrs}, _from, %{current_run: host} = state) when is_pid(host) do
    :ok = ExecutableHost.stop(host)
    {:reply, :ok, %{state | current_run: nil, status: :idle}}
  end

  def handle_call({:send_control, _attrs}, _from, state), do: {:reply, :ok, state}

  def handle_call({:recv_event, timeout}, from, %{pending_events: queue} = state) do
    case :queue.out(queue) do
      {{:value, event}, rest} -> {:reply, {:ok, event}, %{state | pending_events: rest}}
      {:empty, _} ->
        timer_ref = Process.send_after(self(), :recv_timeout, timeout)
        {:noreply, %{state | recv_from: from, recv_timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_info({:executable_host, host, {:stdout, data}}, %{current_run: host} = state),
    do: {:noreply, consume_stdout(state, data)}

  def handle_info({:executable_host, host, {:stderr, _data}}, %{current_run: host} = state),
    do: {:noreply, state}

  def handle_info({:executable_host, host, {:exit_status, 0}}, %{current_run: host} = state),
    do: {:noreply, %{state | current_run: nil, status: :idle}}

  def handle_info({:executable_host, host, {:exit_status, status}}, %{current_run: host} = state),
    do: {:noreply, enqueue_event(state, session_error_frame(state, {:exit_status, status}))}

  def handle_info(:recv_timeout, %{recv_from: from} = state) when not is_nil(from) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | recv_from: nil, recv_timer_ref: nil}}
  end
end
```

Keep the helper functions in the same file for the MVP:

- `build_launch_spec/3`
- `build_pi_args/2`
- `await_support_stream/1`
- `consume_stdout/2`
- `handle_pi_event/2`
- `extract_text_delta/1`
- `assistant_text_from_agent_end/1`
- `fetch_required_string!/2`
- `delta_frame/3`
- `completed_frame/2`
- `session_error_frame/2`

- [ ] **Step 4: Run the focused wrapper tests to verify the rewrite passes**

Run:

```bash
mix test test/prehen/agents/wrappers/pi_coding_agent_test.exs
```

Expected:

```text
0 failures
```

- [ ] **Step 5: Commit the native wrapper rewrite**

```bash
git add lib/prehen/agents/wrappers/pi_coding_agent.ex test/prehen/agents/wrappers/pi_coding_agent_test.exs test/support/fake_pi_json_agent.py
git commit -m "feat: rewrite pi wrapper around native json stream"
```

## Task 2: Rewire High-Level Runtime Tests to the Pi-Native Path

**Files:**
- Create: `test/support/pi_agent_fixture.ex`
- Modify: `test/test_helper.exs`
- Modify: `test/prehen_test.exs`
- Modify: `test/prehen/cli_test.exs`
- Modify: `test/prehen/client/surface_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen/integration/web_inbox_test.exs`
- Modify: `test/prehen_web/channels/session_channel_test.exs`
- Modify: `lib/mix/tasks/prehen.server.ex`

- [ ] **Step 1: Write the failing high-level fixture conversion**

Create a shared helper so all runtime tests point at a fake `pi` implementation instead of `Passthrough`.

```elixir
# test/support/pi_agent_fixture.ex
defmodule Prehen.TestSupport.PiAgentFixture do
  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile

  def profile(name \\ "coder") do
    %Profile{
      name: name,
      label: "Coder",
      implementation: "#{name}_impl",
      default_provider: "openai",
      default_model: "gpt-5",
      prompt_profile: "coder_default",
      workspace_policy: %{mode: "scoped"}
    }
    |> Map.put(:description, "General coding profile")
  end

  def implementation(name \\ "coder", env \\ %{}) do
    %Implementation{
      name: "#{name}_impl",
      command: "python3",
      args: ["test/support/fake_pi_json_agent.py"],
      env: env,
      wrapper: Prehen.Agents.Wrappers.PiCodingAgent
    }
  end

  def registry_state(profile_name \\ "coder", env \\ %{}) do
    profile = profile(profile_name)
    implementation = implementation(profile_name, env)

    %{
      ordered: [profile],
      by_name: %{profile.name => profile},
      supported_ordered: [profile],
      supported_by_name: %{profile.name => profile},
      implementations_ordered: [implementation],
      implementations_by_name: %{implementation.name => implementation}
    }
  end
end
```

Update one top-level test first so the failure is obvious:

```elixir
# test/prehen_test.exs
setup do
  registry_pid = Process.whereis(Registry)
  original = :sys.get_state(registry_pid)

  :sys.replace_state(registry_pid, fn _ -> Prehen.TestSupport.PiAgentFixture.registry_state("coder") end)

  on_exit(fn ->
    :sys.replace_state(registry_pid, fn _ -> original end)
  end)

  :ok
end

test "run/2 executes through the gateway MVP path and returns gateway trace" do
  assert {:ok, result} = Prehen.run("say hi", agent: "coder")
  assert result.answer == "echo:say hi"
end
```

- [ ] **Step 2: Run the high-level runtime tests to verify the old fixtures still leak through**

Run:

```bash
mix test test/prehen_test.exs test/prehen/cli_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs test/prehen_web/channels/session_channel_test.exs
```

Expected:

```text
FAIL
```

with failures still referencing `fake_stdio`, `Passthrough`, `fake_wrapper_agent.exs`, or the debug code inside `mix prehen.server`.

- [ ] **Step 3: Convert all high-level test fixtures and remove temporary startup debugging**

Use the shared fixture in every affected test file and clean `prehen.server`.

```elixir
# test/test_helper.exs
Code.require_file("support/pi_agent_fixture.ex", __DIR__)
ExUnit.start()
```

```elixir
# test/prehen/cli_test.exs
setup do
  registry_pid = Process.whereis(Registry)
  original = :sys.get_state(registry_pid)

  :sys.replace_state(registry_pid, fn _ ->
    Prehen.TestSupport.PiAgentFixture.registry_state("coder")
  end)

  on_exit(fn ->
    :sys.replace_state(registry_pid, fn _ -> original end)
  end)

  :ok
end

test "cli run supports --agent gateway execution path" do
  output =
    capture_io(fn ->
      assert {:ok, %{status: :ok}} =
               Prehen.CLI.main(["run", "--agent", "coder", "hello"])
    end)

  assert output =~ "echo:hello"
end
```

```elixir
# test/prehen/integration/platform_runtime_test.exs
defp coder_profile, do: Prehen.TestSupport.PiAgentFixture.profile("coder")
defp coder_implementation, do: Prehen.TestSupport.PiAgentFixture.implementation("coder")
```

```elixir
# lib/mix/tasks/prehen.server.ex
def run([], opts) when is_list(opts) do
  start_task = Keyword.fetch!(opts, :start_task)
  announce = Keyword.fetch!(opts, :announce)
  wait = Keyword.fetch!(opts, :wait)

  :ok = start_task.("app.start", [])
  _ = announce.("Prehen server listening on #{inbox_url()}")
  wait.()
end
```

Apply the same fixture conversion pattern to:

- `test/prehen/client/surface_test.exs`
- `test/prehen/integration/web_inbox_test.exs`
- `test/prehen_web/channels/session_channel_test.exs`

When a test still needs special wrapper behaviour, keep the custom wrapper module, but replace any raw `Passthrough` delegate with either:

- `PiCodingAgent` plus the shared fake implementation, or
- a local custom wrapper that directly implements `Prehen.Agents.Wrapper`

- [ ] **Step 4: Run the high-level runtime tests again**

Run:

```bash
mix test test/prehen_test.exs test/prehen/cli_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs test/prehen_web/channels/session_channel_test.exs
```

Expected:

```text
0 failures
```

- [ ] **Step 5: Commit the test-path conversion**

```bash
git add lib/mix/tasks/prehen.server.ex test/test_helper.exs test/support/pi_agent_fixture.ex test/prehen_test.exs test/prehen/cli_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs test/prehen_web/channels/session_channel_test.exs
git commit -m "test: route gateway coverage through pi wrapper"
```

## Task 3: Remove Dead Passthrough or Stdio Code and Refresh Docs

**Files:**
- Delete: `lib/prehen/agents/wrappers/passthrough.ex`
- Delete: `lib/prehen/agents/transports/stdio.ex`
- Delete: `test/prehen/agents/wrappers/passthrough_test.exs`
- Delete: `test/prehen/agents/transports/stdio_test.exs`
- Delete: `test/support/fake_wrapper_agent.exs`
- Delete: `test/support/fake_stdio_agent.exs`
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`

- [ ] **Step 1: Delete the old runtime path and its fixtures**

Remove the now-dead files directly once Tasks 1 and 2 are green:

```bash
rm lib/prehen/agents/wrappers/passthrough.ex
rm lib/prehen/agents/transports/stdio.ex
rm test/prehen/agents/wrappers/passthrough_test.exs
rm test/prehen/agents/transports/stdio_test.exs
rm test/support/fake_wrapper_agent.exs
rm test/support/fake_stdio_agent.exs
```

- [ ] **Step 2: Update README and current architecture docs to describe the pi-native path**

Refresh the docs so they no longer describe `stdio + JSON Lines` as the active `pi` integration path.

```markdown
# README.md
- external local agent processes own execution semantics
- the first supported real coding agent is `pi`
- Prehen runs `pi` per turn through a dedicated wrapper
- `/agents` only exposes profiles whose `support_check/1` passes against the configured `pi` executable

## Manual Validation Checklist
1. Configure `coder` to use `Prehen.Agents.Wrappers.PiCodingAgent`.
2. Export `PI_CODING_AGENT_BIN=pi`.
3. Start `mix prehen.server`.
4. Confirm `curl http://localhost:4000/agents` returns `coder`.
5. Open `/inbox`, create a `coder` session, submit `reply with ok`, and confirm streamed assistant output.
```

```markdown
# docs/architecture/current-system.md
6. `Prehen.Agents.Wrappers.PiCodingAgent` owns the session-local wrapper state.
7. `Prehen.Agents.Wrappers.ExecutableHost` launches a per-turn `pi` child process.
8. Native `pi --mode json` events are normalized into `session.output.delta` and `session.output.completed`.
```

- [ ] **Step 3: Run the full verification suite**

Run:

```bash
mix test
mix xref graph --label compile
```

Expected:

```text
mix test      -> 0 failures
mix xref ...  -> exits 0
```

Then run one manual smoke on the configured binary:

```bash
PI_CODING_AGENT_BIN=pi mix test test/prehen/agents/wrappers/pi_coding_agent_test.exs
```

Expected:

```text
real pi smoke path passes
```

- [ ] **Step 4: Commit the cleanup**

```bash
git add README.md docs/architecture/current-system.md
git add -A lib/prehen/agents/wrappers lib/prehen/agents/transports test/prehen/agents test/support
git commit -m "refactor: remove passthrough wrapper path"
```

## Self-Review

### Spec coverage

- Native `pi --mode json` wrapper: covered by Task 1.
- Synthetic `open_session` plus per-turn process launch: covered by Task 1.
- Single in-flight rule: covered by Task 1 tests and wrapper implementation.
- Preserve current Gateway surfaces: covered by Task 2.
- Remove `Passthrough/Stdio` from the MVP path: covered by Task 3.
- Update docs and smoke flow: covered by Task 3.

### Placeholder scan

- No `TODO`, `TBD`, or “similar to above” placeholders remain.
- Every task lists exact file paths and concrete commands.

### Type consistency

- The plan consistently uses `PiCodingAgent`, `ExecutableHost`, `SessionConfig`, `agent_session_id`, `message_id`, `session.output.delta`, and `session.output.completed`.
- High-level tests consistently move from `fake_stdio` or passthrough fixtures to `coder` or shared `PiAgentFixture` data.
