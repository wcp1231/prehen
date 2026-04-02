# Prehen

Prehen is a local-first Agent Gateway and control plane built with Elixir and OTP.

It no longer tries to host a generic in-process agent runtime. Instead:

- external local agent processes own execution semantics
- one gateway session maps to one wrapper-owned agent session
- each submitted turn launches a local `pi --mode json` process
- Prehen handles routing, process supervision, and event forwarding
- HTTP and Phoenix Channels are the primary control/event surface
- the first supported real coding agent is `pi` through `Prehen.Agents.Wrappers.PiCodingAgent`

## MVP Scope

Included in the current MVP:

- `POST /sessions` to create a gateway session
- `POST /sessions/:id/messages` to submit a message
- `GET /sessions/:id` and `GET /agents`
- `GET /inbox` as the operator-facing browser entrypoint
- `/inbox/sessions` JSON endpoints for create/list/detail/history/stop
- `channel: session:<gateway_session_id>` for real-time events
- gateway-backed CLI `run/2`
- normalized `session.output.*` frames from the Pi-native wrapper path

Not included in the MVP:

- persistent session recovery
- multi-node routing or cluster forwarding
- tool mediation through Prehen

## Install

```bash
mix deps.get
```

## Run

Start the local gateway service:

```bash
mix prehen.server
```

Then open `http://localhost:4000/inbox`.

For a one-shot CLI run through the same gateway session flow:

```bash
mix prehen.run --agent coder "列出 lib 并读取 prehen.ex"
```

`--agent` still uses the phase-1 wire name, but the value is a supported profile name such as `coder`.
Prehen resolves that profile to an internal implementation and wrapper before starting the session.

## CLI Options

```text
prehen run --agent NAME "<task>" [--workspace PATH] [--session-id ID] [--timeout-ms N] [--trace-json]
```

## Configuration

The gateway now only reads a small runtime config surface:

- `:prehen, :agent_profiles` application env for boot-time local agent profiles
- `:prehen, :agent_implementations` application env for wrapper-backed local executables
- `PREHEN_TIMEOUT_MS` or `timeout_ms:` override for one-shot run timeouts
- `PREHEN_TRACE_JSON` or `trace_json:` override for CLI trace output

There is no longer a built-in structured config loader for providers, secrets, runtime templates, or workspace layout.

Example profile + implementation wiring for the Pi-native wrapper:

```elixir
config :prehen,
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
      command: System.get_env("PI_CODING_AGENT_BIN") || "pi",
      args: [],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.PiCodingAgent
    }
  ]
```

Users select from supported profiles exposed by `GET /agents`; profiles that fail wrapper support validation in the current environment are not listed or routable.
Each profile carries the user-facing defaults for provider, model, prompt profile, and workspace policy, while Prehen maps the profile to its implementation internally.
`provider` and `model` defaults live on the profile today and may be overridden per session now or through broader API surface later.

`PiCodingAgent` owns `cwd`, prompt payload, provider, model, and workspace env injection, then uses `Prehen.Agents.Wrappers.ExecutableHost` to launch `pi --mode json` for each turn.
Set `PI_CODING_AGENT_BIN` when you want the focused wrapper validation test to hit a concrete local `pi` executable:
the opt-in smoke path verifies wrapper startup, synthetic session open, one message round-trip, and stop behavior against the configured binary.

```bash
PI_CODING_AGENT_BIN=pi mix test test/prehen/agents/wrappers/pi_coding_agent_test.exs
```

## Manual Validation Checklist

1. Configure a supported profile and implementation in `config/runtime.exs` or another loaded config file:

```elixir
config :prehen,
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
      command: System.get_env("PI_CODING_AGENT_BIN") || "pi",
      args: [],
      env: %{},
      wrapper: Prehen.Agents.Wrappers.PiCodingAgent
    }
  ]
```

2. Point Prehen at `pi` and boot the gateway:

```bash
export PI_CODING_AGENT_BIN=pi
mix prehen.server
```

3. Verify the profile is exposed and routable:

```bash
curl http://localhost:4000/agents
```

Confirm the response includes `coder`.

4. Verify one real conversation through `/inbox`:
   Open `http://localhost:4000/inbox`, create a `coder` session, send a short prompt such as `reply with ok`, and confirm the assistant output streams into history and stopping the session leaves the row readable but no longer writable.

5. Reject unsupported integrations when any of these are true:
   The profile does not appear in `GET /agents` or the `/inbox` agent picker, create returns `422` with a classified reason such as `:agent_profile_not_found` or `:agent_implementation_not_found`, or the focused wrapper smoke test returns a classified failure such as `:launch_failed`, `:contract_failed`, `:capability_failed`, or `:policy_rejected`.

## Gateway Surface

Public gateway entrypoints:

- `Prehen.create_session/1`
- `Prehen.submit_message/3`
- `Prehen.session_status/1`
- `Prehen.stop_session/1`
- `Prehen.run/2`

## Inbox Behavior

- `/inbox` is the browser entrypoint for creating sessions, streaming output, reading retained history, and stopping sessions.
- Inbox session state is node-local and non-persistent. Session rows and retained history live only in memory on the current BEAM node.
- Stopped sessions remain visible in `/inbox` until the node restarts, but they become read-only and reject new submits.
- Restarting the node clears retained inbox sessions and their in-memory history.

## Event Model

Gateway events use a stable envelope with:

- `type`
- `gateway_session_id`
- `agent_session_id`
- `agent`
- `node`
- `seq`
- `timestamp`
- `payload`
- `metadata`

The external control surface remains Prehen-specific, while the active runtime path normalizes native `pi --mode json` output into that stable envelope.

## Architecture Docs

- Current system snapshot: `docs/architecture/current-system.md`
- MVP design reference: `docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md`

## Tests

```bash
mix test
```
