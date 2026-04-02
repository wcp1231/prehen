# Prehen Pi Native Wrapper Design

Date: 2026-04-02
Status: Draft approved in brainstorming
Supersedes: the pi-specific direction in `docs/superpowers/specs/2026-03-28-agent-wrapper-integration-design.md`

## 1. Summary

Prehen will integrate `pi` as the first real coding agent by treating `pi --mode json` as the source-of-truth protocol.

The MVP will not require `pi` to implement Prehen's existing `session.open` stdio contract. Instead, Prehen will provide a dedicated `PiCodingAgent` wrapper that:

- owns Gateway-facing session lifecycle
- launches `pi` per user turn
- parses `pi` JSON event stream output
- normalizes `pi` events into Prehen Gateway events

The MVP session model is intentionally constrained:

- one Gateway session maps to one Prehen wrapper process
- one wrapper process may launch multiple `pi` runs over time
- only one `pi` run may be in flight for a session at any moment

## 2. Why This Replaces the Current Pi Path

The current `PiCodingAgent` implementation is a launch-contract shim over `Passthrough`, and `Passthrough` assumes a bidirectional stdio peer that accepts:

- `session.open`
- `session.message`
- `session.control`

and returns:

- `session.opened`
- `session.output.*`

That assumption does not match `pi --mode json`, which emits a native JSON event stream for a turn-oriented CLI invocation rather than a long-lived stdio session protocol.

As a result, keeping `pi` on the current `Passthrough/Stdio` path adds complexity while preserving the wrong abstraction.

## 3. Goals

### 3.1 MVP Goals

- integrate `pi` without modifying `pi` source
- keep existing Gateway HTTP, Channel, and inbox surfaces intact
- keep Prehen in control of workspace, prompt composition, provider, and model
- support real user message submission and streamed assistant output
- support one in-flight turn per session
- support explicit session stop while a turn is running

### 3.2 Non-Goals

- multi-turn concurrency inside one session
- persistent session recovery across node restart
- Prehen-managed tool bridging in this phase
- a generic coding-agent abstraction before the `pi` path is proven
- retaining `Passthrough` or `Stdio` as active MVP dependencies for `pi`

## 4. Pi Protocol Assumptions

Prehen will treat the documented `pi --mode json` output format as authoritative:

- the first stdout line is a session header, such as `{"type":"session",...}`
- subsequent stdout lines are event objects such as `agent_start`, `turn_start`, `message_update`, `tool_execution_*`, and `agent_end`
- a single `pi` process run represents one submitted turn from Prehen's point of view

The wrapper will not assume that `pi` supports:

- interactive stdin session control
- a native `session.open` handshake
- multiple user turns over one long-lived process

## 5. High-Level Architecture

### 5.1 Preserved Layers

- `Gateway`
  Owns session creation, routing, inbox projection, and channels.
- `ExecutableHost`
  Owns external process hosting, stdout or stderr forwarding, and exit reporting.
- `PiCodingAgent`
  Owns `pi`-specific adaptation and event normalization.

### 5.2 Removed from the Pi MVP Path

- `Passthrough`
- `Stdio`

These modules may be deleted if they are no longer used elsewhere. They are not part of the `pi` MVP runtime path.

### 5.3 New Runtime Shape

1. Gateway starts `PiCodingAgent`.
2. `open_session` creates wrapper-local session state and returns a synthetic `agent_session_id`.
3. `send_message` starts one `pi --mode json` run for that turn.
4. `PiCodingAgent` consumes native `pi` JSON lines from stdout.
5. `PiCodingAgent` emits normalized Prehen session events through `recv_event`.
6. When `pi` finishes, the wrapper returns to `idle`.

## 6. Wrapper Contract

`PiCodingAgent` continues to implement the existing `Prehen.Agents.Wrapper` behaviour so that `SessionWorker` does not need a transport-specific branch.

Required wrapper functions remain:

- `start_link/1`
- `open_session/2`
- `send_message/2`
- `send_control/2`
- `recv_event/2`
- `stop/1`
- `support_check/1`

The important change is semantic, not behavioural shape:

- `open_session/2` no longer starts or probes a live `pi` process
- `send_message/2` becomes the point where a `pi` turn process is started

## 7. Session Model

### 7.1 Wrapper State

The wrapper process should keep only the minimum session state needed for the MVP:

- `gateway_session_id`
- `agent_session_id`
- `profile_name`
- `provider`
- `model`
- `prompt_profile`
- `workspace`
- `status`
- `pending_events`
- `current_run`
- `conversation_state`

`conversation_state` is wrapper-owned state used to prepare the next `pi` invocation. MVP may keep this minimal and in-memory only.

### 7.2 Status States

- `idle`
  Ready to accept a user turn
- `running`
  One `pi` run is active
- `stopped`
  Session is terminated and must reject new submits

### 7.3 Single In-Flight Rule

If the wrapper is in `running`, `send_message/2` must return `{:error, :session_busy}`.

This is an explicit MVP rule, not a temporary bug.

## 8. Launch Model

### 8.1 `open_session`

`open_session/2` will:

- validate required session fields
- ensure the workspace exists
- generate a stable synthetic `agent_session_id`
- store session defaults in wrapper state
- return `{:ok, %{agent_session_id: ...}}`

It will not:

- launch `pi`
- wait for any external handshake

### 8.2 `send_message`

`send_message/2` will:

- reject when the wrapper is not `idle`
- derive the turn prompt from session defaults and conversation state
- launch `pi --mode json ...` through `ExecutableHost`
- mark the wrapper `running`
- start buffering normalized output events

The exact CLI shape should be implementation-owned by `PiCodingAgent`. The MVP requirement is only that provider, model, prompt, and workspace are applied consistently to the `pi` invocation.

### 8.3 `send_control`

MVP control scope is intentionally small:

- support stop or cancel of the active turn by terminating the running `pi` process
- if no turn is active, respond successfully without extra side effects

Native `pi` cancel support may be used later if it exists and proves reliable, but the MVP must not depend on it.

## 9. Event Normalization

### 9.1 Gateway Events Emitted by the Wrapper

The wrapper should normalize `pi` output into these Gateway-facing events:

- `session.output.delta`
- `session.output.completed`
- `session.error`
- optional `session.status`

### 9.2 Pi-to-Prehen Mapping

Recommended MVP mapping:

- `session`
  Store as wrapper metadata only. Do not project directly as a user-visible output event.
- `agent_start`
  Internal status transition only.
- `turn_start`
  Internal status transition only.
- `message_update` with assistant text delta
  Emit `session.output.delta`.
- `message_end`
  Update the wrapper's latest assistant message snapshot.
- `turn_end`
  Optional internal completion checkpoint.
- `agent_end`
  Emit `session.output.completed` and transition back to `idle`.
- `tool_execution_*`
  Ignore for inbox rendering in MVP, but leave room to trace or expose later.

### 9.3 Delta Extraction Rule

The wrapper should only emit `session.output.delta` for assistant text deltas. Non-text updates should not be projected into the inbox transcript in the MVP.

## 10. Support Check

`support_check/1` should no longer probe for a synthetic `session.opened` handshake.

Instead it should validate:

- `pi` command resolves and can launch
- workspace policy is acceptable
- prompt, provider, and model can be translated into a launch spec
- one minimal `pi --mode json` run can start and emit a structurally valid JSON stream

MVP acceptance is black-box:

- launch succeeds
- stdout begins with a valid `session` header
- the run reaches a recognizable completion or error boundary

If any of those fail, the profile must not be exposed by `/agents`.

## 11. Failure Classification

The existing failure categories remain useful and should be applied as follows:

- `launch_failed`
  `pi` cannot be found, launched, or kept alive long enough to start the run.
- `contract_failed`
  `pi` starts, but the wrapper cannot parse or normalize a valid JSON event stream.
- `capability_failed`
  provider, model, prompt, or workspace constraints cannot be applied reliably.
- `policy_rejected`
  the session config requests an unsupported workspace policy or another explicitly rejected operating mode.

## 12. Module and Code Boundaries

### 12.1 Keep

- `Prehen.Agents.Wrappers.ExecutableHost`
- `Prehen.Gateway.SessionWorker`
- existing Gateway HTTP and Channel surfaces

### 12.2 Rewrite

- `Prehen.Agents.Wrappers.PiCodingAgent`

It should become a real wrapper state machine instead of a `Passthrough` adapter.

### 12.3 Remove from MVP Path

- `Prehen.Agents.Wrappers.Passthrough`
- `Prehen.Agents.Transports.Stdio`

If tests or configs still depend on them, those dependencies should be removed as part of the refactor rather than preserved for compatibility.

## 13. Testing Strategy

### 13.1 Required Automated Coverage

- `open_session` returns a synthetic `agent_session_id` without launching `pi`
- `send_message` launches one run when idle
- `send_message` rejects with `:session_busy` while running
- native `pi` JSON deltas map to `session.output.delta`
- run completion maps to `session.output.completed`
- malformed or incompatible JSON stream becomes `:contract_failed`
- stop terminates the active `pi` process and leaves the session in a predictable terminal or idle state

### 13.2 Black-Box Smoke

The focused wrapper smoke should use the real configured `pi` executable and confirm:

- `/agents` exposes the configured profile
- a session can be created
- one user prompt produces streamed or final assistant output
- stop works during or after a turn without orphaning the child process

## 14. Evolution Path

If the `pi` wrapper works well, it becomes the reference shape for future coding-agent integrations.

The next abstraction should happen only after the `pi` path is proven. That future abstraction should be based on the proven pattern:

- wrapper-owned session state
- per-turn external process launch
- native event stream parsing
- Prehen event normalization

The future generic layer should not be based on the old `Passthrough` session-open protocol unless another supported agent genuinely matches that model.

## 15. Success Criteria

This design is successful when all of the following are true:

- `coder` backed by `pi` appears in `/agents`
- a user can create a session through existing Gateway surfaces
- a submitted user message starts a real `pi` turn
- assistant text reaches inbox history through normalized Gateway events
- only one turn may be active per session
- stopping a running turn terminates the child process predictably
- no source modification to `pi` is required
