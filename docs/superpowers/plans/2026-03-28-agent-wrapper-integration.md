# Agent Wrapper Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Prehen-owned wrapper integration layer so supported external agent executables can run through the current Gateway while Prehen controls workspace, prompt, provider, and model selection.

**Architecture:** Keep the current single-node Gateway, inbox, and Channel surfaces. Introduce user-facing agent profiles, developer-facing implementations, and an Elixir wrapper contract that sits between `SessionWorker` and a concrete executable. Preserve the current fake stdio path through a passthrough wrapper first, then add a `pi-coding-agent` wrapper and validation path.

**Tech Stack:** Elixir 1.19, Phoenix 1.8, OTP, Ports/stdin-stdout process hosting, ExUnit, vanilla JS inbox, executable-driven agent integration

---

## Scope Check

This plan intentionally covers one bounded project:

- add profile/implementation configuration
- add a wrapper abstraction and runtime bridge
- preserve current Gateway and inbox behavior through the wrapper path
- validate `pi-coding-agent` as the first supported external implementation

It does not cover:

- multi-node routing
- persistent memory or recovery
- full MCP tool implementation
- custom in-process agent runtimes
- broad UI redesign beyond profile-facing wiring already required by the existing inbox

## File Structure

### New files

- `lib/prehen/agents/implementation.ex`
  Developer-facing struct for concrete executable integrations.
- `lib/prehen/agents/session_config.ex`
  Resolved per-session policy object containing profile, provider, model, prompt, and workspace.
- `lib/prehen/agents/prompt_context.ex`
  Prehen-owned prompt composition for wrapper startup.
- `lib/prehen/agents/wrapper.ex`
  Behavior for Prehen-owned wrappers.
- `lib/prehen/agents/wrappers/passthrough.ex`
  Wrapper that preserves the current stdio/transport-backed behavior behind the new contract.
- `lib/prehen/agents/wrappers/pi_coding_agent.ex`
  First agent-specific wrapper for `pi-coding-agent`.
- `lib/prehen/agents/wrappers/executable_host.ex`
  Focused process host for launching and monitoring executable-backed integrations.
- `test/prehen/config_test.exs`
  Covers profile/implementation normalization and session config resolution.
- `test/prehen/agents/prompt_context_test.exs`
  Covers prompt composition from profile defaults and session overrides.
- `test/prehen/agents/wrappers/passthrough_test.exs`
  Covers wrapper contract behavior against a deterministic fake transport-backed implementation.
- `test/prehen/agents/wrappers/pi_coding_agent_test.exs`
  Covers `pi-coding-agent` wrapper mapping and env-gated executable validation.
- `test/support/fake_wrapper_agent.exs`
  Deterministic executable fixture that echoes provider/model/prompt/workspace through wrapper-friendly events.

### Files to modify

- `lib/prehen/agents/profile.ex`
  Expand from raw executable profile to user-facing agent profile shape.
- `lib/prehen/config.ex`
  Normalize `agent_profiles` + `agent_implementations`, then resolve session config defaults.
- `lib/prehen/agents/registry.ex`
  Store profiles and implementations, keeping lookups explicit.
- `lib/prehen/gateway/router.ex`
  Route by user-facing profile name and return the selected profile/implementation pair.
- `lib/prehen/client/surface.ex`
  Accept profile/provider/model/workspace overrides and pass resolved session config into session startup.
- `lib/prehen/gateway/session_worker.ex`
  Replace direct transport startup with wrapper-backed startup while preserving inbox/event semantics.
- `lib/prehen/agents/transports/stdio.ex`
  Keep transport behavior focused so the passthrough wrapper can reuse it cleanly.
- `lib/prehen/agents/protocol/frame.ex`
  Add fields needed for prompt/provider/model/workspace propagation.
- `lib/prehen_web/controllers/agent_controller.ex`
  Return supported user-facing profiles rather than raw implementation details.
- `lib/prehen_web/controllers/session_controller.ex`
  Accept profile/provider/model/workspace overrides on the control-plane API.
- `lib/prehen_web/controllers/inbox_controller.ex`
  Accept the same profile-facing create options as the inbox entrypoint.
- `test/prehen/client/surface_test.exs`
  Cover resolved session config and wrapper-backed session creation.
- `test/prehen/gateway/session_worker_test.exs`
  Cover wrapper-backed startup, event normalization, and stop semantics.
- `test/prehen/integration/platform_runtime_test.exs`
  Keep the platform runtime HTTP surface green with profile-facing semantics.
- `test/prehen/integration/web_inbox_test.exs`
  Keep inbox create/list flows green with supported profiles.
- `README.md`
  Document profiles, wrapper-backed integrations, and first-target setup.
- `docs/architecture/current-system.md`
  Update current architecture to reflect profile/implementation/wrapper layering.

### Deliberate decomposition choices

- `SessionWorker` should know about a wrapper contract, not about `pi-coding-agent` or any future implementation directly.
- The passthrough wrapper lands before the `pi-coding-agent` wrapper so the current Gateway path stays testable during the refactor.
- Session policy resolution lives in a dedicated `SessionConfig` struct instead of being spread across controllers, router, and worker maps.
- `Surface` owns final session config resolution so `Router` can stay focused on profile selection.
- User-facing profile changes should remain compatible with the current inbox UI by treating the existing `agent` field as the profile identifier in phase 1.

## Task 1: Lock the Profile, Implementation, and Session Config Contract

**Files:**
- Create: `test/prehen/config_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen/integration/web_inbox_test.exs`
- Modify: `lib/prehen/agents/profile.ex`
- Create: `lib/prehen/agents/implementation.ex`
- Create: `lib/prehen/agents/session_config.ex`
- Create: `lib/prehen/agents/prompt_context.ex`
- Modify: `lib/prehen/config.ex`
- Modify: `lib/prehen/agents/registry.ex`
- Modify: `lib/prehen/gateway/router.ex`
- Modify: `lib/prehen_web/controllers/agent_controller.ex`
- Create: `test/prehen/agents/prompt_context_test.exs`

- [ ] **Step 1: Write the failing config normalization test**

```elixir
defmodule Prehen.ConfigTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Agents.SessionConfig
  alias Prehen.Config

  test "normalizes profiles implementations and session defaults" do
    config =
      Config.load(
        agent_profiles: [
          %{
            name: "coder",
            label: "Coder",
            implementation: "pi_coding_agent",
            default_provider: "openai",
            default_model: "gpt-5",
            prompt_profile: "coder_default",
            workspace_policy: %{mode: "scoped"}
          }
        ],
        agent_implementations: [
          %{
            name: "pi_coding_agent",
            command: "pi-coding-agent",
            args: ["serve"],
            env: %{},
            wrapper: Prehen.Agents.Wrappers.PiCodingAgent
          }
        ]
      )

    assert [%Profile{name: "coder", implementation: "pi_coding_agent"}] = config.agent_profiles

    assert [
             %Implementation{
               name: "pi_coding_agent",
               wrapper: Prehen.Agents.Wrappers.PiCodingAgent
             }
           ] = config.agent_implementations

    assert %SessionConfig{
             profile_name: "coder",
             provider: "openai",
             model: "gpt-5",
             prompt_profile: "coder_default"
           } = Config.resolve_session_config!(config, agent: "coder")
  end
end
```

- [ ] **Step 2: Run the config test to verify it fails**

Run: `mix test test/prehen/config_test.exs`
Expected: FAIL because `Implementation`, `SessionConfig`, and `resolve_session_config!/2` do not exist yet.

- [ ] **Step 3: Extend the HTTP integration tests with profile-facing semantics**

Add assertions that:

- `GET /agents` returns supported profiles rather than raw executable names
- `POST /sessions` accepts `agent: "coder"` and returns that profile name
- `POST /inbox/sessions` does the same

Use a deterministic registry setup like:

```elixir
profile = %Profile{
  name: "coder",
  label: "Coder",
  implementation: "fake_stdio_impl",
  default_provider: "openai",
  default_model: "gpt-5",
  prompt_profile: "coder_default",
  workspace_policy: %{mode: "scoped"}
}
```

- [ ] **Step 4: Run the targeted integration tests to verify they fail**

Run: `mix test test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: FAIL because the current controller and registry shapes only understand raw executable-style profiles.

- [ ] **Step 5: Implement the new config and registry structs**

Implement:

- `Prehen.Agents.Implementation`
- expanded `Prehen.Agents.Profile`
- `Prehen.Agents.SessionConfig`
- `Config.resolve_session_config!/2`

Normalization rules for phase 1:

- profile `name`, `label`, `implementation`, `default_provider`, `default_model`, `prompt_profile`, and `workspace_policy` are required
- implementation `name`, `command`, `args`, and `wrapper` are required
- implementation `env` defaults to `%{}`
- missing required fields are dropped during normalization rather than half-normalized

- [ ] **Step 6: Add prompt composition primitives**

Add a focused prompt module that can build the phase 1 wrapper prompt context from:

- `prompt_profile`
- provider/model metadata
- workspace context
- optional capability context

Lock it with a unit test in `test/prehen/agents/prompt_context_test.exs`.

- [ ] **Step 7: Update registry, router, and `/agents` to return supported profiles**

Implementation expectations:

- `Registry.all/0` returns ordered user-facing profiles
- `Registry.fetch!/1` continues to fetch by profile name
- add implementation lookup support without exposing it to the controller
- `Router.route/1` continues to select a supported profile by name and expose the bound implementation metadata needed later
- `/agents` continues to return the current shape, but the `agent` field now means profile name

- [ ] **Step 8: Run the focused config and integration tests**

Run: `mix test test/prehen/config_test.exs test/prehen/agents/prompt_context_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/prehen/agents/profile.ex lib/prehen/agents/implementation.ex lib/prehen/agents/session_config.ex lib/prehen/agents/prompt_context.ex lib/prehen/config.ex lib/prehen/agents/registry.ex lib/prehen/gateway/router.ex lib/prehen_web/controllers/agent_controller.ex test/prehen/config_test.exs test/prehen/agents/prompt_context_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs
git commit -m "feat: add profile and implementation config model"
```

## Task 2: Introduce the Wrapper Contract and Preserve the Current Runtime Path

**Files:**
- Create: `lib/prehen/agents/wrapper.ex`
- Create: `lib/prehen/agents/wrappers/executable_host.ex`
- Create: `lib/prehen/agents/wrappers/passthrough.ex`
- Create: `test/prehen/agents/wrappers/passthrough_test.exs`
- Modify: `lib/prehen/agents/transports/stdio.ex`

- [ ] **Step 1: Write the failing passthrough wrapper test**

```elixir
defmodule Prehen.Agents.Wrappers.PassthroughTest do
  use ExUnit.Case, async: false

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.SessionConfig
  alias Prehen.Agents.Wrappers.Passthrough

  test "opens submits and receives normalized frames through the wrapper contract" do
    implementation = %Implementation{
      name: "fake_stdio_impl",
      command: "mix",
      args: ["run", "--no-start", "test/support/fake_stdio_agent.exs"],
      env: %{},
      wrapper: Passthrough
    }

    session_config = %SessionConfig{
      profile_name: "coder",
      implementation: implementation,
      provider: "openai",
      model: "gpt-5",
      prompt_profile: "coder_default",
      workspace: "/tmp/prehen_wrapper_test"
    }

    assert {:ok, wrapper} = Passthrough.start_link(session_config: session_config)
    assert {:ok, %{agent_session_id: "agent_gw_wrapper"}} = Passthrough.open_session(wrapper, %{gateway_session_id: "gw_wrapper"})
    assert :ok = Passthrough.send_message(wrapper, %{message_id: "msg_1", parts: [%{type: "text", text: "hi"}]})
    assert {:ok, %{"type" => "session.output.delta"}} = Passthrough.recv_event(wrapper, 1_000)
  end
end
```

- [ ] **Step 2: Run the wrapper test to verify it fails**

Run: `mix test test/prehen/agents/wrappers/passthrough_test.exs`
Expected: FAIL because the wrapper behavior and passthrough module do not exist yet.

- [ ] **Step 3: Add the wrapper behavior and executable host**

Define a dedicated wrapper behavior with callbacks that match the Gateway-facing contract:

- `start_link/1`
- `open_session/2`
- `send_message/2`
- `send_control/2`
- `recv_event/2`
- `support_check/1`
- `stop/1`

`ExecutableHost` should own only:

- launching the executable
- maintaining the OS process handle
- exposing stdout/stderr and exit state

Do not mix agent-specific protocol translation into the host.

- [ ] **Step 4: Implement the passthrough wrapper around the current stdio transport**

The passthrough wrapper should:

- accept a `SessionConfig`
- internally start the current stdio transport path
- translate `open_session`, `send_message`, `send_control`, and `recv_event`
- preserve the existing fake stdio contract so current tests stay meaningful

- [ ] **Step 5: Run the focused wrapper tests**

Run: `mix test test/prehen/agents/wrappers/passthrough_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/prehen/agents/wrapper.ex lib/prehen/agents/wrappers/executable_host.ex lib/prehen/agents/wrappers/passthrough.ex lib/prehen/agents/transports/stdio.ex test/prehen/agents/wrappers/passthrough_test.exs
git commit -m "feat: add wrapper contract and passthrough runtime"
```

## Task 3: Thread Session Policy Through Surface, Controllers, and SessionWorker

**Files:**
- Modify: `lib/prehen/client/surface.ex`
- Modify: `lib/prehen/gateway/session_worker.ex`
- Modify: `lib/prehen/agents/protocol/frame.ex`
- Modify: `lib/prehen_web/controllers/session_controller.ex`
- Modify: `lib/prehen_web/controllers/inbox_controller.ex`
- Create: `test/support/fake_wrapper_agent.exs`
- Modify: `test/prehen/gateway/session_worker_test.exs`
- Modify: `test/prehen/client/surface_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen/integration/web_inbox_test.exs`

- [ ] **Step 1: Write the failing session policy propagation test**

Extend `test/prehen/client/surface_test.exs` with a deterministic wrapper-backed implementation that asserts the resolved session policy reaches the wrapper:

```elixir
test "create_session resolves provider model prompt and workspace before wrapper startup" do
  assert {:ok, %{session_id: session_id, agent: "coder"}} =
           Surface.create_session(
             agent: "coder",
             provider: "anthropic",
             model: "claude-sonnet",
             workspace: "/tmp/prehen_surface_workspace"
           )

  assert_receive {:wrapper_opened,
                  %{
                    profile_name: "coder",
                    provider: "anthropic",
                    model: "claude-sonnet",
                    workspace: "/tmp/prehen_surface_workspace",
                    prompt_profile: "coder_default"
                  }}

  assert is_binary(session_id)
end
```

- [ ] **Step 2: Run the surface test to verify it fails**

Run: `mix test test/prehen/client/surface_test.exs`
Expected: FAIL because `Surface` and `SessionWorker` currently pass only agent name and workspace.

- [ ] **Step 3: Extend the HTTP tests with provider and model overrides**

Add failing assertions that:

- `POST /sessions` accepts `provider` and `model`
- `POST /inbox/sessions` accepts the same fields
- the created session still reports the user-facing profile name

- [ ] **Step 4: Run the targeted integration tests to verify they fail**

Run: `mix test test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: FAIL because the controllers discard these fields today.

- [ ] **Step 5: Implement session policy threading**

Implementation expectations:

- `Surface.create_session/1` resolves `SessionConfig` before worker startup
- `SessionWorker.start_session/2` receives the resolved config, not just an agent name
- `Frame.session_open/1` and related messages carry prompt/provider/model/workspace fields the wrapper needs
- `PromptContext.build/1` composes the final prompt string or structured context before wrapper startup
- controllers pass through `agent`, `provider`, `model`, and `workspace` when present

Do not expose `prompt_profile` override on the public HTTP surface in phase 1.

- [ ] **Step 6: Strengthen `SessionWorker` tests for wrapper-backed semantics**

Add failing assertions that:

- `SessionWorker` stores the resolved profile name in route state
- wrapper startup failures retain terminal registry metadata
- existing normalized delta events still reach inbox projection and PubSub

- [ ] **Step 7: Add the fake wrapper executable fixture and run the focused suite**

Run: `mix test test/prehen/client/surface_test.exs test/prehen/gateway/session_worker_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/prehen/client/surface.ex lib/prehen/gateway/session_worker.ex lib/prehen/agents/protocol/frame.ex lib/prehen_web/controllers/session_controller.ex lib/prehen_web/controllers/inbox_controller.ex test/support/fake_wrapper_agent.exs test/prehen/gateway/session_worker_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs
git commit -m "feat: thread session policy through wrapper startup"
```

## Task 4: Implement the `pi-coding-agent` Wrapper and Validation Path

**Files:**
- Create: `lib/prehen/agents/wrappers/pi_coding_agent.ex`
- Create: `test/prehen/agents/wrappers/pi_coding_agent_test.exs`
- Modify: `lib/prehen/config.ex`
- Modify: `README.md`

- [ ] **Step 1: Write the failing wrapper contract test for `pi-coding-agent`**

Add a test that locks the expected mapping behavior without requiring the real executable yet:

```elixir
test "maps session policy into the pi-coding-agent launch contract" do
  session_config = %SessionConfig{
    profile_name: "coder",
    provider: "openai",
    model: "gpt-5",
    prompt_profile: "coder_default",
    prompt_context: "You are Prehen coder.",
    workspace: "/tmp/prehen_pi_workspace"
  }

  assert {:ok, launch} = PiCodingAgent.build_launch_spec(session_config)
  assert launch.cwd == "/tmp/prehen_pi_workspace"
  assert launch.env["PREHEN_PROVIDER"] == "openai"
  assert launch.env["PREHEN_MODEL"] == "gpt-5"
  assert launch.prompt_payload =~ "You are Prehen coder."
end
```

- [ ] **Step 2: Run the wrapper test to verify it fails**

Run: `mix test test/prehen/agents/wrappers/pi_coding_agent_test.exs`
Expected: FAIL because the wrapper module does not exist yet.

- [ ] **Step 3: Implement the `pi-coding-agent` wrapper launch and event mapping**

Implementation expectations:

- centralize `build_launch_spec/1`
- implement `support_check/1` returning `:ok` or classified failures such as `{:error, :launch_failed}`, `{:error, :contract_failed}`, `{:error, :capability_failed}`, or `{:error, :policy_rejected}`
- classify launch failures as `launch_failed`
- classify missing or unstable session semantics as `contract_failed`
- classify failed prompt/provider/model/workspace control as `capability_failed`
- classify integrations that fundamentally violate Prehen support rules as `policy_rejected`
- leave MCP and advanced capability bridging out of scope for this task

- [ ] **Step 4: Add an env-gated executable validation test**

In the same test file, add a test guarded by `System.get_env("PI_CODING_AGENT_BIN")` that:

- launches the real executable through the wrapper
- verifies `support_check/1`
- verifies prompt/provider/model/workspace injection reaches the executable through the wrapper contract
- verifies open session
- verifies one message round-trip
- verifies stop or cancel behavior

When the env var is absent, skip the test with a clear message rather than failing the suite.

- [ ] **Step 5: Run the focused wrapper tests**

Run: `mix test test/prehen/agents/wrappers/pi_coding_agent_test.exs`
Expected: PASS, with the real executable test either passing or skipping cleanly when the binary is not configured.

- [ ] **Step 6: Commit**

```bash
git add lib/prehen/agents/wrappers/pi_coding_agent.ex test/prehen/agents/wrappers/pi_coding_agent_test.exs lib/prehen/config.ex README.md
git commit -m "feat: add pi-coding-agent wrapper bridge"
```

## Task 5: Expose Supported Profiles Through the Existing Product Surfaces

**Files:**
- Modify: `lib/prehen_web/controllers/agent_controller.ex`
- Modify: `lib/prehen_web/controllers/session_controller.ex`
- Modify: `lib/prehen_web/controllers/inbox_controller.ex`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen/integration/web_inbox_test.exs`
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`

- [ ] **Step 1: Write the failing profile-facing HTTP assertions**

Extend the integration tests to require:

- `GET /agents` returns profile-facing fields such as `agent`, `name`, `default`, and `description` when present
- `POST /sessions` and `POST /inbox/sessions` continue to accept `agent`, but that value is now a supported profile name
- unknown profile names return a structured not-found or unprocessable error rather than a KeyError

- [ ] **Step 2: Run the integration tests to verify they fail**

Run: `mix test test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: FAIL on at least the unknown-profile or description expectations.

- [ ] **Step 3: Implement the product-surface profile contract**

Implementation expectations:

- keep `agent` as the wire field name in phase 1 for backward compatibility
- treat its value as profile name everywhere
- enrich `/agents` with any user-facing metadata already present on the profile
- avoid exposing implementation names, wrapper modules, or internal support checks
- only expose profiles that have already passed wrapper support validation in the configured environment

- [ ] **Step 4: Update docs to explain the profile-facing model**

Document:

- users pick supported profiles
- Prehen maps profiles to implementations internally
- provider/model defaults live on the profile and may be overridden when the API chooses to expose them

- [ ] **Step 5: Run the focused integration tests**

Run: `mix test test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/prehen_web/controllers/agent_controller.ex lib/prehen_web/controllers/session_controller.ex lib/prehen_web/controllers/inbox_controller.ex test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs README.md docs/architecture/current-system.md
git commit -m "feat: expose supported agent profiles"
```

## Task 6: Final Verification and Implementation Readiness

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture/current-system.md`
- Modify: `test/prehen/gateway/session_worker_test.exs`
- Modify: `test/prehen/client/surface_test.exs`
- Modify: `test/prehen/integration/platform_runtime_test.exs`
- Modify: `test/prehen/integration/web_inbox_test.exs`

- [ ] **Step 1: Add final assertions for the red-line validation criteria**

Lock tests for:

- provider/model overrides reach wrapper startup
- workspace reaches wrapper startup
- prompt context reaches wrapper startup
- session stop leaves no live worker route for the normal success path
- unsupported or misconfigured implementations fail with classified errors

- [ ] **Step 2: Run the targeted suite**

Run: `mix test test/prehen/config_test.exs test/prehen/agents/wrappers/passthrough_test.exs test/prehen/agents/wrappers/pi_coding_agent_test.exs test/prehen/client/surface_test.exs test/prehen/gateway/session_worker_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs`
Expected: PASS

- [ ] **Step 3: Run full verification**

Run: `mix test`
Expected: `0 failures`

Run: `mix xref graph --label compile`
Expected: succeeds without reintroducing runtime-era compile dependencies

- [ ] **Step 4: Update the manual validation checklist in README**

Document:

- how to configure a supported profile
- how to point Prehen at `pi-coding-agent`
- how to verify one real conversation through `/inbox`
- how to tell whether the integration should be rejected as unsupported

- [ ] **Step 5: Commit**

```bash
git add README.md docs/architecture/current-system.md test/prehen/gateway/session_worker_test.exs test/prehen/client/surface_test.exs test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs test/prehen/config_test.exs test/prehen/agents/wrappers/passthrough_test.exs test/prehen/agents/wrappers/pi_coding_agent_test.exs
git commit -m "test: lock wrapper integration acceptance"
```
