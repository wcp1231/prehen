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
- `GET /inbox` as the operator-facing browser entrypoint
- `/inbox/sessions` JSON endpoints for create/list/detail/history/stop
- `channel: session:<gateway_session_id>` for real-time events
- gateway-backed CLI `run/2`
- ACP-inspired internal frames over a transport adapter

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

## CLI Options

```text
prehen run --agent NAME "<task>" [--workspace PATH] [--session-id ID] [--timeout-ms N] [--trace-json]
```

## Configuration

The gateway now only reads a small runtime config surface:

- `:prehen, :agent_profiles` application env for boot-time local agent profiles
- `PREHEN_TIMEOUT_MS` or `timeout_ms:` override for one-shot run timeouts
- `PREHEN_TRACE_JSON` or `trace_json:` override for CLI trace output

There is no longer a built-in structured config loader for providers, secrets, runtime templates, or workspace layout.

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

The transport adapter is ACP-inspired internally, but the external control surface remains Prehen-specific.

## Architecture Docs

- Current system snapshot: `docs/architecture/current-system.md`
- MVP design reference: `docs/superpowers/specs/2026-03-27-single-node-agent-gateway-mvp-design.md`

## Tests

```bash
mix test
```
