# Prehen Profile Runtime Environment Design

Date: 2026-04-02
Status: Draft approved in brainstorming
Builds on:
- `docs/superpowers/specs/2026-03-28-agent-wrapper-integration-design.md`
- `docs/superpowers/specs/2026-04-02-pi-native-wrapper-design.md`

## 1. Summary

Prehen will evolve from “a gateway that can launch `pi`” into “a gateway that provides a stable runtime environment for user-facing agent profiles”.

The current runtime implementation remains `pi`, but users do not select raw runtimes. Users select `agent profiles`, and each profile has its own fixed directory under `~/.prehen/profiles/<profile_id>`.

That profile directory becomes the profile's long-lived working environment. It stores profile-specific files such as:

- `AGENTS.md`
- `SOUL.md`
- `skills/`
- `memory/`

Prehen is responsible for:

- loading user-facing configuration from `~/.prehen/config.yaml`
- resolving profile metadata and profile directories
- building the system prompt from fixed prompt fragments
- exposing Prehen-managed higher-level capabilities through MCP
- isolating MCP capability access by gateway session

The first MCP tools introduced by this design are:

- `skills.search`
- `skills.load`

These are exposed by Prehen through a session-scoped local HTTP MCP interface. Skills are no longer injected wholesale into the prompt.

## 2. Terminology

To avoid the ambiguity that appeared during design discussion, the following terms are fixed:

### 2.1 Agent Runtime

The concrete executable implementation that performs reasoning and execution.

Current runtime:

- `pi`

This is an internal implementation concern, not the primary user-facing selection concept.

### 2.2 Agent Profile

The user-facing agent choice exposed by Prehen.

A profile defines:

- its identifier and label
- its default provider and model
- its intended role or usage mode
- its fixed filesystem directory
- its prompt fragments and profile-private skills

Users choose profiles, not runtimes.

### 2.3 Gateway Session

A concrete conversation session created through Prehen.

A gateway session binds:

- one selected profile
- one wrapper-owned runtime session
- one session-scoped MCP authorization context

## 3. Goals

### 3.1 Goals

- keep `pi` as the current runtime while improving the profile environment around it
- make profiles the stable user-facing abstraction
- give each profile a fixed directory under `~/.prehen`
- build system prompts from fixed profile files instead of ad hoc inline strings
- stop embedding skill bodies directly into prompts
- expose higher-level Prehen capabilities through MCP
- scope MCP access to a single gateway session
- adopt a user-friendly top-level config file format instead of relying on `.exs`

### 3.2 Non-Goals

- replacing `pi` in this phase
- introducing directory scanning as the source of profile registration
- finalizing database-backed configuration in this phase
- building a fully generic prompt templating DSL
- building a full structured memory platform in this phase
- implementing all future MCP tools in this phase

## 4. High-Level Architecture

The runtime path becomes:

1. `Prehen.Client.Surface` resolves a user-facing profile from config.
2. `SessionWorker` starts the selected wrapper session.
3. `ProfileEnvironment` resolves the fixed profile directory and its files.
4. `PromptBuilder` composes the runtime system prompt from fixed fragments.
5. `SessionMCPContext` creates a session-scoped local MCP authorization context.
6. `PiCodingAgent` launches `pi` with the resolved prompt, workspace, provider, model, and MCP connection metadata.
7. `pi` calls Prehen MCP tools when it needs higher-level capabilities such as skill discovery.

Responsibility split:

- `Prehen`
  Owns configuration, profile resolution, prompt construction, MCP tool hosting, authorization, and session routing.
- `PiCodingAgent`
  Owns runtime-specific launch translation for `pi`.
- `pi`
  Owns reasoning and tool usage decisions.

## 5. Filesystem Contract

### 5.1 Prehen Root Directory

Prehen owns a fixed root directory:

- `~/.prehen`

Phase-1 root layout:

- `~/.prehen/config.yaml`
- `~/.prehen/profiles/<profile_id>/`
- `~/.prehen/skills/`
- `~/.prehen/cache/`
- `~/.prehen/logs/`
- `~/.prehen/tmp/`

### 5.2 Profile Directory

Each profile has a fixed directory:

- `~/.prehen/profiles/<profile_id>/`

Phase-1 required or reserved contents:

- `AGENTS.md`
- `SOUL.md`
- `skills/`
- `memory/`

Phase-1 meaning:

- `AGENTS.md`
  Profile-specific operating instructions, execution rules, and collaboration constraints.
- `SOUL.md`
  Role definition, voice, identity, and longer-lived behavior guidance.
- `skills/`
  Skills private to this profile.
- `memory/`
  Reserved location for profile-specific memory files and future memory features.

The profile directory is the profile's fixed working environment. Prehen must not allow profile directories outside `~/.prehen/profiles`.

### 5.3 Global Skills Directory

Prehen also owns:

- `~/.prehen/skills/`

This contains skills visible to all profiles unless future policy says otherwise.

### 5.4 Workspace Rule

For profile-based runtimes in this design, the profile directory itself is the runtime workspace.

That means:

- workspace is fixed per profile
- workspace is not chosen ad hoc per session
- the runtime should execute with `cwd` rooted at `~/.prehen/profiles/<profile_id>`
- profile files and runtime work products share the same stable directory boundary

This intentionally replaces the earlier temporary single-node MVP behavior where a session could be created against an arbitrary workspace path.

## 6. Configuration Model

### 6.1 User-Facing Config File

Prehen introduces a user-facing configuration file:

- `~/.prehen/config.yaml`

This file is the main operator-editable configuration surface.

It should be human-editable and must not require Elixir knowledge.

### 6.2 Scope of Config

This config file is not profile-only. It is the root user config for the local Prehen node and should eventually cover:

- `profiles`
- `providers`
- `channels`
- other platform-level settings

Examples of future channel scope:

- Telegram
- Slack
- Web

### 6.3 Profile Registration

Profiles are registered from configuration, not from directory scanning.

That rule is explicit because:

- profile registration must remain compatible with future database-backed sources
- directory scanning makes ownership and validation harder to reason about
- user-visible profiles should come from intentional configuration, not filesystem coincidence

### 6.4 Internal Evolution Rule

Phase 1 may still use Elixir runtime config as an internal bridge where needed, but the target contract is:

- user-facing configuration lives in `~/.prehen/config.yaml`
- future database-backed configuration maps into the same internal schema

## 7. Profile Model

Each user-facing profile should have fields equivalent to:

- `id`
- `label`
- `description`
- `runtime`
- `default_provider`
- `default_model`
- `enabled`

Resolved fields, not user-editable path inputs:

- `profile_dir`
  Always derived as `~/.prehen/profiles/<profile_id>`

The user should not provide an arbitrary filesystem path for a profile directory.

For phase 1:

- `runtime` is expected to be `pi`
- multiple profiles may still point to the same runtime

This keeps the distinction clear:

- many profiles
- one current runtime implementation

The resolved runtime workspace for a profile is always:

- `~/.prehen/profiles/<profile_id>`

## 8. Prompt Construction

### 8.1 Fixed Composition Rule

Prompt construction is fixed in code for phase 1.

Composition order:

1. Prehen global system instructions
2. profile `SOUL.md`
3. profile `AGENTS.md`
4. runtime context

Runtime context should include at least:

- selected profile id
- selected provider
- selected model
- resolved profile workspace path
- MCP capability summary

### 8.2 Why Fixed Composition

Phase 1 intentionally avoids a prompt templating DSL.

The goal is to stabilize:

- where prompt material comes from
- what order it appears in
- what belongs in prompt versus MCP

This is simpler than a template system and reduces design churn while the runtime environment model is still being proven.

### 8.3 Prompt Boundary Rule

Skill bodies must not be embedded wholesale in the system prompt.

Instead:

- the prompt should mention that skills exist
- the prompt should instruct the runtime to search and load skills when needed
- actual skill content is fetched through MCP

## 9. Skills Model

### 9.1 Skill Layers

Phase 1 supports two skill scopes:

- global skills from `~/.prehen/skills/`
- profile-private skills from `~/.prehen/profiles/<profile_id>/skills/`

### 9.2 Visibility Rules

Inside one gateway session, the runtime may access:

- all global skills
- only the selected profile's private skills

It must not access:

- another profile's private skills

### 9.3 MCP Tools

Phase-1 skills capabilities are exposed as MCP tools:

- `skills.search`
- `skills.load`

`skills.search` should return compact metadata such as:

- stable skill id
- skill name
- short summary
- scope (`global` or `profile`)

`skills.load` should return the selected skill body and related metadata for one skill id.

### 9.4 Prompt Contract for Skills

The prompt should describe the workflow, not inline the content:

- search first
- load second
- use loaded skill content when relevant

This keeps prompt size stable even if skill count grows substantially.

## 10. MCP Architecture

### 10.1 MCP Ownership

Prehen is the MCP tool host.

Prehen-managed higher-level capabilities must be exposed to runtimes through MCP rather than custom per-runtime tool contracts.

### 10.2 Session-Scoped Context

MCP access is scoped by gateway session.

This means MCP authorization and visibility are isolated per gateway session even if Prehen runs as a single local server process.

The execution context for a tool call must know:

- `gateway_session_id`
- selected `profile_id`
- authorized capability set

### 10.3 Transport

Phase-1 MCP transport is local HTTP.

This is preferred over stdio bridge commands because:

- it avoids multiplying local helper commands
- it keeps Prehen as the single MCP host
- it is easier to reason about as a stable local service boundary

Socket transports may be added later, but are not the first implementation target.

### 10.4 Endpoint Model

Prehen should keep one server process and expose MCP through the existing local Prehen service boundary rather than spinning up a separate standalone application per session.

Session isolation is achieved through session-bound authorization, not through one full HTTP listener per session.

Phase-1 implementation requirements:

- MCP access must be local-only
- every session gets a short-lived random authorization token
- that token is bound to one gateway session
- the token becomes invalid when the session stops

### 10.5 Passing MCP Access to `pi`

`PiCodingAgent` is responsible for translating the session's MCP endpoint information into whatever `pi` launch contract proves valid.

That translation is wrapper-owned.

The design does not assume the exact final `pi` flag shape in advance, but it does require a real integration validation path.

## 11. MCP Tool Roadmap

### 11.1 Phase-1 Tools

- `skills.search`
- `skills.load`

### 11.2 Reserved Future Namespaces

The naming direction should be fixed now so future tools remain coherent:

- `skills.*`
- `session.*`
- `message.*`
- `spawn.*`
- `browser.*`

Phase 1 does not need to implement these future namespaces, but the naming direction should be treated as reserved.

## 12. Session Lifecycle Changes

### 12.1 Session Creation

When a session is created:

1. Prehen resolves the selected profile from config.
2. Prehen resolves the profile directory under `~/.prehen/profiles/<profile_id>`.
3. Prehen loads prompt fragments and skill visibility information.
4. Prehen creates a session-scoped MCP authorization context.
5. `PiCodingAgent` opens the runtime session with resolved provider, model, fixed profile workspace, prompt, and MCP metadata.

### 12.2 Message Submission

When the user submits a turn:

1. `PiCodingAgent` launches one `pi` turn process.
2. `pi` receives the fixed prompt plus MCP connection details.
3. `pi` may call `skills.search` and `skills.load`.
4. Prehen serves those MCP calls within the session's allowed scope.
5. `pi` produces streamed output that is normalized back into gateway events.

### 12.3 Session Stop

When the session stops:

- the runtime process is stopped as today
- the session's MCP token is invalidated
- further MCP tool use for that session is rejected

## 13. Error Handling

Phase 1 should classify at least these failures:

- config file missing or unreadable
- config file malformed
- selected profile missing or disabled
- profile directory missing
- prompt files unreadable
- MCP token invalid or expired
- skill not found
- skill not visible in the current session scope
- `pi` runtime does not successfully connect to or use the MCP interface

Errors should stay classified and observable rather than collapsing into generic launch failures whenever practical.

## 14. Validation and Testing

### 14.1 Unit Tests

- config parser and schema validation
- profile directory resolution
- prompt builder composition order
- skill index and visibility filtering
- session-scoped MCP authorization

### 14.2 Integration Tests

- session creation resolves the configured profile environment
- prompt fragments are loaded from profile files
- MCP requests are accepted only for the owning session
- `skills.search` and `skills.load` return only allowed results

### 14.3 Black-Box Smoke

Real smoke acceptance for phase 1 must include a real `pi` run that proves:

- the resolved prompt path still works
- the MCP endpoint details are usable by `pi`
- `skills.search` and `skills.load` can be called in a real session

This should be treated as an explicit acceptance gate, not an optional future check.

## 15. Delivery Phases

### 15.1 Phase 1

Implement:

- `~/.prehen/config.yaml`
- configured profile catalog
- fixed profile directory contract
- prompt builder
- session-scoped local HTTP MCP authorization
- `skills.search`
- `skills.load`
- real `pi` compatibility validation

Do not implement yet:

- database-backed configuration
- full structured memory APIs
- broad MCP tool families beyond skills

### 15.2 Phase 2

Extend with:

- memory model and memory tools
- additional MCP tool namespaces such as `session.*`, `message.*`, and `browser.*`
- stronger policy and observability around tool access

### 15.3 Phase 3

Extend with:

- alternate config sources such as database-backed profile catalogs
- config reload or synchronization strategy
- possible additional runtime implementations beyond `pi`

## 16. Architecture Consequences

This design changes the center of gravity of the current system:

- from “wrapper launches `pi`”
- to “Prehen provides a profile runtime environment in which `pi` operates”

That makes the next phase of Prehen more coherent:

- profiles become the stable product abstraction
- prompt construction becomes deterministic
- skills stop inflating prompts
- MCP becomes the standard boundary for higher-level Prehen capabilities

This also keeps the repo aligned with the long-term direction already discussed:

- Elixir remains the control plane
- external runtimes keep reasoning outside Elixir
- higher-level coordination features live in Prehen, not inside each runtime implementation
