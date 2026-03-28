# Prehen Agent Wrapper Integration Design

Date: 2026-03-28
Status: Draft approved in brainstorming

## 1. Summary

Prehen will extend the current single-node Gateway so it can run real external agents through a Prehen-owned wrapper layer rather than requiring each agent to implement the Gateway protocol directly.

The goal is not to support arbitrary agents with no contract. The goal is to make it practical for developers to add supported agents without rewriting Prehen for every agent family and without forcing invasive changes into each agent implementation.

The recommended first target is `pi-coding-agent`, treated as a black-box executable. Prehen should first attempt to integrate it through a wrapper without modifying the agent itself. If that fails cleanly against explicit criteria, that result should inform whether a Prehen-compatible custom agent runtime is needed later.

## 2. Why This Exists

The current Gateway already proves these pieces:

- Prehen can create sessions over HTTP and Web
- Prehen can launch one external process per session
- Prehen can stream normalized events back through Channels
- Prehen can hold node-local inbox state and session history

What is still missing is a stable integration model for real agents.

Today the system assumes a simple stdio JSON-line peer. That is sufficient for `fake_stdio` testing, but not sufficient for practical agent integration where Prehen must also control:

- workspace assignment and boundaries
- prompt injection
- provider selection
- model selection
- high-level Prehen-managed capabilities such as `session`, `spawn`, `browser`, and `message`

This design introduces a wrapper layer so Prehen can own those control-plane concerns while leaving reasoning and agent-local execution inside the external agent.

## 3. Design Goals

### 3.1 Goals

- keep Prehen as the session, routing, and control-plane owner
- keep external agent reasoning outside Elixir
- allow Prehen to integrate supported agents with minimal or no agent-side source changes
- let Prehen decide session-level `provider` and `model`
- let Prehen compose and inject prompt context
- let Prehen allocate and constrain the session workspace
- expose only supported agents or profiles to end users
- make agent integration repeatable for developers through a clear contract

### 3.2 Non-Goals

- claiming that any executable can be integrated automatically
- exposing protocol or capability negotiation details to end users
- forcing Prehen to own agent memory in the first phase
- reintroducing an in-process generic agent runtime in Elixir
- requiring all external agents to implement MCP or a new Prehen-native protocol directly

## 4. User Model vs Developer Model

### 4.1 User Model

Users should not need to understand wrappers, MCP, capability negotiation, or agent-specific protocol differences.

Users should see:

- a list of supported agent profiles
- defaults selected by Prehen
- optional overrides such as provider or model when the product surface chooses to expose them

From the user perspective, Prehen provides supported agents as productized choices.

### 4.2 Developer Model

Developers integrating a new agent need a lower-level model:

- a concrete external executable
- a Prehen wrapper that can host and adapt that executable
- a support contract that determines whether the integration is good enough to expose as a supported profile

Capability checks and integration negotiation belong to this developer-facing layer, not to the user-facing product model.

## 5. Three-Layer Integration Model

### 5.1 Agent Profile

This is the user-visible product layer.

An agent profile describes the experience Prehen exposes to users, not just the command it runs.

Recommended fields:

- `name`
- `label`
- `description`
- `implementation`
- `default_provider`
- `default_model`
- `prompt_profile`
- `workspace_policy`
- `capability_set`
- `session_defaults`

Multiple profiles may point at the same implementation.

Phase 1 required fields:

- `name`
- `label`
- `implementation`
- `default_provider`
- `default_model`
- `prompt_profile`
- `workspace_policy`

Deferred or productization-oriented fields:

- `description`
- `capability_set`
- `session_defaults`

Examples:

- `coder`
- `fast_coder`
- `researcher`

These may all map to the same underlying implementation with different defaults.

### 5.2 Agent Implementation

This is the developer-facing integration layer for a concrete executable.

Recommended fields:

- `name`
- `command`
- `args`
- `env`
- `wrapper`
- `launch_mode`
- `provider_bridge_mode`
- `prompt_bridge_mode`
- `workspace_bridge_mode`
- `memory_mode`

The implementation layer should remain hidden from normal user choice.

Phase 1 required fields:

- `name`
- `command`
- `args`
- `env`
- `wrapper`

Deferred or refinement-oriented fields:

- `launch_mode`
- `provider_bridge_mode`
- `prompt_bridge_mode`
- `workspace_bridge_mode`
- `memory_mode`

### 5.3 Wrapper

This is the technical bridge layer owned by Prehen.

The wrapper is responsible for adapting one implementation family into the uniform Gateway-facing session model.

It should be implemented in Elixir so it can align with the current supervision, lifecycle, logging, and failure semantics already present in the Gateway.

## 6. Core Architecture

Prehen should no longer treat a real external agent as the direct peer of the current transport.

Instead:

1. Gateway starts a wrapper-backed session worker.
2. The wrapper starts the real external agent executable.
3. The wrapper injects session policy and capability context.
4. The wrapper translates between Prehen session semantics and the agent's native interface.
5. The wrapper normalizes events back into the Gateway event stream.

This creates three clear responsibilities:

- `Gateway`
  Owns sessions, routing, inbox, Web and Channel surfaces, permissions, and policy.
- `Wrapper`
  Owns agent-specific adaptation and capability injection.
- `Agent Executable`
  Owns reasoning, agent-local tools, and its internal runtime behavior.

## 7. Wrapper Internal Responsibilities

The wrapper should remain a session bridge, not a second agent runtime.

Recommended internal responsibilities:

- host and monitor the external agent process
- inject workspace and session context
- inject prompt, provider, and model choices
- expose Prehen-managed capabilities
- normalize output events
- handle stop or cancel behavior
- surface launch and protocol failures clearly

Recommended internal modules:

- `ExecutableHost`
- `SessionBridge`
- `CapabilityBridge`
- `EventNormalizer`

The exact module split may evolve, but these concerns should stay isolated.

## 8. Prehen-to-Wrapper Contract

The Gateway should speak a stable contract to wrappers rather than agent-specific protocols.

Required inbound session actions:

- `session.open`
- `session.message`
- `session.control`

Required outbound events:

- `session.opened`
- `session.status`
- `session.output.delta`
- `session.output.completed`
- `session.tool`
- `session.error`
- `session.closed`

This contract is internal to Prehen integration work. It is not the user-facing product surface.

Terminology rules:

- UI or client `submit` maps to wrapper contract `session.message`
- UI or client `stop` or `cancel` maps to wrapper contract `session.control`
- implementation planning should treat `submit`, `stop`, and `cancel` as product-surface actions, not as separate wrapper event types

## 9. Control-Plane Ownership

### 9.1 Workspace

Workspace is owned by Prehen.

Prehen must:

- allocate the session workspace
- decide workspace policy
- bind session to workspace
- pass the resolved workspace to the wrapper

The wrapper must ensure the external agent runs in the assigned workspace and receives whatever workspace context its native interface requires.

### 9.2 Prompt

Prompt composition is owned by Prehen.

Prehen should build the final session prompt context from:

- prompt profile
- workspace context
- capability context
- session metadata
- channel or client metadata when relevant

The wrapper is responsible only for translating that prompt context into the native interface of the integrated agent.

### 9.3 Provider and Model

Provider and model selection are owned by Prehen.

Prehen should decide which `provider` and `model` a session uses, with this product model:

- profile defines defaults
- session creation may override them
- wrapper translates the final choice into agent-native args, env, or config

Authentication still matters operationally, but the product-level decision is which provider and model the session uses, not which raw auth reference the user picks.

### 9.4 Tools

Tools are divided into two classes.

#### Agent-Local Tools

Examples:

- `read`
- `write`
- `ls`
- other local file or shell operations already native to the agent

In the first phase these remain agent-owned, as long as the workspace boundary is still controlled by Prehen.

#### Prehen-Managed Capabilities

Examples:

- `session`
- `spawn`
- `browser`
- `message`

These should be provided by Prehen, because they cross permission boundaries, may span sessions, and should be audited and constrained centrally.

MCP is the preferred exposure mechanism where the agent supports it. If the target agent does not support MCP, the wrapper may bridge these capabilities through an agent-specific adaptation path.

### 9.5 Memory

Memory remains agent-owned in the first phase.

Prehen should not treat inbox projection or gateway trace state as canonical agent memory.

The wrapper may declare whether the integrated agent behaves as:

- `agent_managed`
- `ephemeral`
- `resumable`
- `unknown`

That information is for Prehen integration and operational policy, not for direct user choice.

## 10. Internal Support Evaluation

Prehen still needs an internal way to determine whether an implementation is supportable, but this is not a user-facing negotiation surface.

The wrapper or implementation should be evaluated internally for:

- stable multi-turn session behavior
- stream or final-answer behavior
- stop or cancel behavior
- workspace enforcement
- prompt injection
- provider and model injection
- Prehen-managed capability bridging when required

If an implementation cannot satisfy the internal support contract, it should not be registered as a supported user-facing profile.

Acceptance matrix for the first validation cycle:

- turn completion is acceptable when the wrapper can detect a stable end-of-turn signal from the target implementation often enough that Gateway session status does not remain stuck in `running` after a normal answer
- stop or cancel is acceptable when Prehen can terminate an active turn or session without leaving an orphaned live process in the normal success path
- stream handling is acceptable when either incremental output can be surfaced reliably or the implementation is explicitly classified as `final_only` for planning purposes

## 11. Failure Categories

Integration failures should be classified clearly.

### 11.1 `launch_failed`

The wrapper cannot launch the executable or maintain the process.

### 11.2 `contract_failed`

The process launches, but the wrapper cannot establish stable session semantics or event mapping.

### 11.3 `capability_failed`

Basic conversation works, but required control-plane concerns such as workspace, prompt, provider, or model injection do not work reliably.

### 11.4 `policy_rejected`

The executable can run, but its behavior does not satisfy Prehen's product or safety constraints and therefore should not be exposed as a supported profile.

## 12. Red Lines for No-Source-Change Integration

The attempt to integrate `pi-coding-agent` or another executable without modifying the agent source should be considered unsuccessful if any of these are true:

- Prehen cannot reliably choose the session provider and model
- Prehen cannot reliably inject prompt context
- Prehen cannot reliably constrain the workspace
- the wrapper cannot determine turn completion well enough for stable session semantics
- stop or cancel cannot be made reliable enough for the session model
- Prehen-managed capabilities require invasive source changes inside the target agent
- wrapper complexity grows to the point that it is effectively recreating a new agent runtime

Failure against these criteria should be treated as a useful architectural result, not as wasted work.

## 13. First Target: `pi-coding-agent`

The first concrete integration target should be `pi-coding-agent`, treated as a black-box executable.

The first implementation goal is not complete feature parity. It is to determine whether `pi-coding-agent` can be exposed as a supported Prehen profile with:

- Prehen-owned workspace
- Prehen-owned prompt composition
- Prehen-owned provider and model selection
- stable multi-turn session behavior
- streamed or otherwise acceptable output behavior
- stop or cancel semantics good enough for Gateway sessions

If this succeeds, it validates the wrapper direction.

If this fails against the red lines above, Prehen should use that result to define what a future Prehen-compatible custom agent runtime must provide.

## 14. Phased Delivery

### Phase 1: Wrapper Baseline

- introduce wrapper abstraction in the Gateway
- route session startup through a wrapper rather than directly through a raw executable peer
- support session open, submit, output, and stop
- support workspace, prompt, provider, and model injection paths

### Phase 2: `pi-coding-agent` Integration

- implement the first agent-specific wrapper
- validate no-source-change integration against the support criteria
- keep scope focused on real session correctness before advanced capabilities

### Phase 3: Prehen-Managed Capabilities

- expose `session`, `spawn`, and `message`
- add `browser` after the earlier bridge is stable
- prefer MCP where supported
- fall back to wrapper-specific bridging only for supported implementations

### Phase 4: Productization and Policy

- refine permission model
- refine profile defaults and override rules
- document integration contract for adding more supported agents
- prepare for a second implementation family

## 15. Success Criteria

The first two phases should be considered successful if all of the following are true:

- Prehen can expose a real supported profile backed by `pi-coding-agent`
- a user can create a session through the existing Gateway surfaces
- Prehen chooses the workspace, prompt, provider, and model for that session
- the agent can produce a real reply through the current session and inbox flow
- session stop or cancel is reliable enough for the current Gateway model
- the agent executable does not need source modification for the integration attempt

Advanced Prehen-managed capabilities do not need to be complete for the first success milestone, but the architecture must leave room for them.

For milestone planning, `reliable enough` should mean:

- normal request and response turns do not leave the session in a permanently ambiguous state
- a stop or cancel request can be mapped to either a native cancel path or a wrapper-owned process termination path with predictable session closure semantics
- the wrapper can classify any remaining limitations explicitly enough that Prehen can decide whether to expose or reject the implementation

## 16. Planning Boundaries

This design should lead to an implementation plan focused on one bounded project:

- add a Prehen-owned wrapper integration layer for supported external agents

That plan may then be decomposed into implementation phases, but the design should not branch into unrelated work such as multi-node routing, persistent recovery, or a full custom in-process agent runtime.
