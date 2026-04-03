# Prehen Current Architecture

_Last updated: 2026-04-03_

This document describes the current single-node Prehen gateway as implemented today.

Prehen is now a profile-based local gateway:

- user-facing selection is a profile
- profile config comes from `~/.prehen/config.yaml`
- each profile has a fixed home under `~/.prehen/profiles/<profile_id>`
- that profile directory is the runtime workspace
- prompt construction is file-based and deterministic
- higher-level platform capabilities are exposed through local HTTP MCP
- the active runtime implementation is `PiCodingAgent` launching `pi --mode json`

## 1. Hot Path

The current session path is:

```text
CLI / HTTP / Channel clients
    |
    v
Prehen
    |
    v
Prehen.Client.Surface
    |
    +--> Prehen.Gateway.Router
    +--> Prehen.ProfileEnvironment
    +--> Prehen.PromptBuilder
    |
    v
Prehen.Gateway.SessionWorker
    |
    +--> Prehen.Gateway.SessionRegistry
    +--> Prehen.Gateway.InboxProjection
    +--> Prehen.Observability.TraceCollector
    +--> Prehen.MCP.SessionAuth
    |
    v
Prehen.Agents.Wrappers.PiCodingAgent
    |
    +--> Prehen.Agents.Wrappers.PiLaunchContract
    +--> Prehen.Agents.Wrappers.ExecutableHost
    |
    +--> local `pi --mode json` process
    |
    +--> local HTTP MCP (`/mcp`)
             |
             +--> Prehen.MCP.ToolDispatch
             +--> Prehen.MCP.Tools.Skills
```

The system remains single-node and in-memory. There is no durable recovery layer yet.

## 2. Responsibilities

### 2.1 `Prehen.Client.Surface`

- resolves the selected profile through the gateway router
- rejects ad hoc workspace overrides
- loads the fixed profile environment
- builds the resolved `SessionConfig`
- starts, stops, and submits to gateway sessions

### 2.2 `Prehen.Gateway.Router`

- selects the requested supported profile
- falls back to the default supported profile when the request omits `agent`
- keeps profile selection separate from implementation selection

### 2.3 `Prehen.ProfileEnvironment`

- resolves `~/.prehen` and `~/.prehen/profiles/<profile_id>`
- ensures the fixed profile workspace exists
- resolves `SOUL.md`, `AGENTS.md`, `skills/`, and `memory/`
- defines the stable profile runtime boundary

### 2.4 `Prehen.PromptBuilder`

- builds the runtime system prompt in fixed order
- keeps prompt construction deterministic
- mentions MCP-based skill usage instead of embedding skill bodies wholesale

### 2.5 `Prehen.Agents.Registry`

- stores configured profiles and runtime implementations
- runs wrapper `support_check/1` at startup
- exposes only supported profiles to `/agents`

### 2.6 `Prehen.Gateway.SessionWorker`

- owns one gateway session
- starts the selected wrapper
- binds `gateway_session_id` to the wrapper session
- creates session-scoped MCP auth metadata
- passes session-scoped MCP URL/token into wrapper startup
- records and broadcasts normalized gateway events

### 2.7 `Prehen.MCP.SessionAuth`

- issues bearer tokens bound to one gateway session and profile
- carries the current session capability set
- invalidates tokens on session stop
- can recover auth context from live session workers after an auth-server restart

### 2.8 `Prehen.MCP.ToolDispatch`

- serves the current MCP JSON-RPC surface
- currently supports `tools/list` and `tools/call`
- filters visible tools by the session capability set

### 2.9 `Prehen.MCP.Tools.Skills`

- indexes global skills from `~/.prehen/skills/`
- indexes private skills from `~/.prehen/profiles/<profile_id>/skills/`
- exposes `skills.search`
- exposes `skills.load`
- keeps skill visibility scoped to the selected profile

### 2.10 `Prehen.Agents.Wrappers.PiCodingAgent`

- is the active runtime wrapper for coding profiles
- keeps wrapper-local conversation state
- uses the fixed profile workspace
- appends the resolved system prompt on launch
- probes `pi` for MCP ingestion contract support
- launches one `pi` process per user turn
- normalizes `pi` JSON events into gateway events

### 2.11 `Prehen.Agents.Wrappers.PiLaunchContract`

- probes `pi --help`
- classifies whether the installed runtime exposes a recognized MCP ingestion contract
- currently recognizes HTTP flag and HTTP env styles

### 2.12 `PrehenWeb`

- serves `/sessions`, `/agents`, `/inbox`, and `/mcp`
- keeps `/mcp` local-only
- exposes SessionChannel streaming on `session:<gateway_session_id>`

## 3. Current Data Flow

### 3.1 Session Creation

1. Client calls `POST /sessions`, `POST /inbox/sessions`, or `Prehen.create_session/1`.
2. `Surface` resolves the supported profile through `Gateway.Router`.
3. `ProfileEnvironment` resolves the fixed profile directory.
4. `PromptBuilder` builds the resolved system prompt from global instructions, `SOUL.md`, `AGENTS.md`, and runtime context.
5. `SessionWorker` starts and issues session-scoped MCP auth.
6. `PiCodingAgent.open_session/2` stores session defaults and returns a synthetic `agent_session_id`.
7. `SessionRegistry` stores route metadata.
8. `InboxProjection` records the session row for `/inbox`.

### 3.2 Message Submission

1. Client submits a turn over HTTP, SessionChannel, or `Prehen.submit_message/3`.
2. `Surface` finds the live worker by `gateway_session_id`.
3. `SessionWorker` forwards the turn to `PiCodingAgent`.
4. `PiCodingAgent` builds the launch spec from fixed workspace, provider, model, system prompt, and any recognized MCP contract metadata.
5. `ExecutableHost` launches one local `pi --mode json` process for that turn.
6. `PiCodingAgent` parses native `pi` JSON events and emits normalized gateway events.
7. `SessionWorker` broadcasts them and updates inbox projection state.

### 3.3 MCP Calls

1. A running `pi` process receives MCP connection metadata when a recognized contract is available.
2. `pi` calls local `POST /mcp` with the session bearer token.
3. `MCPController` enforces local-only access and token auth.
4. `ToolDispatch` resolves the tool call within the session capability set.
5. `Skills` returns only global skills and the selected profile's private skills.

### 3.4 Stop And Retention

1. Client stops the session through HTTP or `Prehen.stop_session/1`.
2. The worker terminates the active wrapper and invalidates the MCP token.
3. `SessionRegistry` retains terminal route metadata for status reads.
4. `InboxProjection` retains session detail and history until node restart.

## 4. Current Constraints

- single node only
- one in-flight turn per session
- profile workspace is fixed; no ad hoc workspace path per session
- profile registration comes from `~/.prehen/config.yaml`, not directory scanning
- only `skills.search` and `skills.load` are implemented today
- MCP transport is local HTTP only
- real `pi` MCP contract smoke is opt-in
- inbox rows and retained history are node-local in-memory state
- no durable recovery or multi-node routing yet
