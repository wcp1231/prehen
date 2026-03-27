# Prehen

Prehen is a local-first Agent Gateway and control plane built with Elixir and OTP.

It no longer tries to host a generic in-process agent runtime. Instead:

- external local agent processes own session truth and execution semantics
- one session maps to one local agent process
- Prehen handles routing, process supervision, and event forwarding
- HTTP and Phoenix Channels are the primary control/event surface
- the first supported transport is `stdio + JSON Lines`

## MVP Scope

Included in the current MVP:

- `POST /sessions` to create a gateway session
- `POST /sessions/:id/messages` to submit a message
- `GET /sessions/:id` and `GET /agents`
- `channel: session:<gateway_session_id>` for real-time events
- gateway-backed CLI `run/2`
- ACP-inspired internal frames over a transport adapter

Not included in the MVP:

- legacy runtime session APIs such as resume/replay/list workspace sessions
- persistent session recovery
- multi-node routing or cluster forwarding
- tool mediation through Prehen

## Install

```bash
mix deps.get
```

## Run

The project still exposes a CLI entrypoint, but it now runs through the gateway-backed session flow:

```bash
mix escript.build
./prehen run --agent coder "列出 lib 并读取 prehen.ex"
```

```bash
mix prehen.run --agent coder "列出 lib 并读取 prehen.ex"
```

## CLI Options

```text
prehen run --agent NAME "<task>" [--workspace PATH] [--session-id ID] [--timeout-ms N] [--trace-json]
```

## Configuration

Local agent profiles are configured through structured files:

- `$WORKSPACE_DIR/.prehen/config/providers.yaml`
- `$WORKSPACE_DIR/.prehen/config/agents.yaml`
- `$WORKSPACE_DIR/.prehen/config/runtime.yaml`
- `$WORKSPACE_DIR/.prehen/config/secrets.yaml`

Workspace-level config wins over `$HOME/.prehen/global/config/*`.

## Gateway Surface

Public gateway entrypoints:

- `Prehen.create_session/1`
- `Prehen.submit_message/3`
- `Prehen.session_status/1`
- `Prehen.stop_session/1`
- `Prehen.run/2`

Explicitly unsupported in the gateway MVP:

- `Prehen.resume_session/2`
- `Prehen.await_result/2`
- `Prehen.list_sessions/1`
- `Prehen.replay_session/2`
- `Prehen.set_capability_packs/2`
- `Prehen.subscribe_events/1`

These now fail with a structured `unsupported_api` error instead of delegating into the removed runtime path.

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

The transport adapter is ACP-inspired internally, but the external control surface remains Prehen-specific.

## Architecture Docs

- Current system snapshot: `docs/architecture/current-system.md`
- MVP design reference: `docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md`

## Tests

```bash
mix test
```
