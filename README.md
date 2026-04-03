# Prehen

Prehen is a local-first Agent Gateway built with Elixir and OTP.

Current direction:

- users select profiles, not raw runtimes
- each profile lives under `~/.prehen/profiles/<profile_id>`
- the profile directory is the fixed runtime workspace
- Prehen builds the system prompt and owns session routing
- `PiCodingAgent` launches local `pi --mode json` processes per turn
- higher-level Prehen capabilities are exposed through local HTTP MCP

## MVP

Included today:

- `POST /sessions`
- `POST /sessions/:id/messages`
- `GET /sessions/:id`
- `GET /agents`
- `GET /inbox`
- `/inbox/sessions` JSON endpoints
- `session:<gateway_session_id>` Phoenix Channel streaming
- profile-based prompt and workspace resolution
- session-scoped MCP auth plus `skills.search` and `skills.load`

Not included yet:

- persistent session recovery
- multi-node routing
- database-backed config
- MCP namespaces beyond `skills.*`

## Install

```bash
mix deps.get
```

## Run

Start the local gateway:

```bash
mix prehen.server
```

Then open `http://localhost:4000/inbox`.

For a one-shot CLI run through the same gateway flow:

```bash
mix prehen.run --agent coder "list lib and inspect prehen.ex"
```

CLI usage:

```text
prehen run --agent NAME "<task>" [--session-id ID] [--timeout-ms N] [--trace-json]
```

`--workspace` is gone. Workspace is fixed by the selected profile.

## User Config

User-facing config now lives in `~/.prehen/config.yaml`.

Example:

```yaml
profiles:
  - id: coder
    label: Coder
    runtime: pi
    default_provider: github-copilot
    default_model: gpt-5.4-mini
    enabled: true
```

The current runtime implementation is still `pi`, but users work with profiles.

## Profile Layout

Each profile has a fixed directory:

```text
~/.prehen/profiles/<profile_id>/
  AGENTS.md
  SOUL.md
  skills/
  memory/
```

Bootstrap one profile:

```bash
mkdir -p ~/.prehen/profiles/coder/skills
mkdir -p ~/.prehen/profiles/coder/memory
printf "You are Coder.\n" > ~/.prehen/profiles/coder/SOUL.md
printf "Always be precise.\n" > ~/.prehen/profiles/coder/AGENTS.md
```

Prompt composition is fixed in code:

1. global Prehen instructions
2. profile `SOUL.md`
3. profile `AGENTS.md`
4. runtime context

Prehen treats the profile directory itself as the runtime workspace. Sessions do not accept ad hoc workspace overrides.

## Skills And MCP

Skills are no longer injected wholesale into the system prompt.

Prehen exposes the first profile-scoped MCP tools over local HTTP:

- `skills.search`
- `skills.load`

Visibility rules:

- global skills come from `~/.prehen/skills/`
- profile-private skills come from `~/.prehen/profiles/<profile_id>/skills/`
- a session can see global skills plus only its selected profile's private skills

MCP access is session-scoped:

- each gateway session gets its own bearer token
- tokens are bound to one gateway session and profile
- tokens are invalidated when the session stops
- requests must be local-only

## Pi Runtime Notes

`PiCodingAgent` now launches `pi` from the fixed profile workspace and appends the resolved system prompt to each turn launch.

Prehen also probes whether the installed `pi` exposes a recognized MCP ingestion contract. Deterministic wrapper tests use a fake `pi` fixture; a real `pi` contract smoke remains opt-in:

```bash
PREHEN_REAL_PI_MCP_CONTRACT=1 mix test --no-start test/prehen/integration/pi_mcp_contract_smoke_test.exs
```

## Manual Validation

1. Create `~/.prehen/config.yaml` and the profile directory shown above.
2. Ensure `pi` is installed and already authenticated for the provider you want to use.
3. Start the gateway with `mix prehen.server`.
4. Check `GET /agents` or load `/inbox`.
5. Create a `coder` session and send a short prompt.
6. Confirm streamed output appears and the session remains readable after stop.

If `/agents` is empty, the configured profile failed wrapper support validation in the current environment.

## Tests

Focused commands used for the current runtime environment work:

```bash
mix test --no-start test/prehen/mcp/session_auth_test.exs test/prehen/mcp/tools/skills_test.exs
mix test --no-start test/prehen/agents/wrappers/pi_launch_contract_test.exs test/prehen/agents/wrappers/pi_coding_agent_test.exs
PORT=4033 mix test test/prehen/integration/platform_runtime_test.exs test/prehen/integration/web_inbox_test.exs
```

## Architecture

- current system snapshot: `docs/architecture/current-system.md`
- profile runtime environment design: `docs/superpowers/specs/2026-04-02-profile-runtime-environment-design.md`
