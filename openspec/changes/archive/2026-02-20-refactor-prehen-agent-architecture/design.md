## Context

当前 Prehen 仍以单 Agent、单会话 CLI 执行为中心，核心流程集中在 `Runtime -> Session -> JidoAI backend`，存在以下问题：
- 会话编排、队列管理、状态采集、trace 组装耦合在同一实现中，边界不清。
- Jido runtime 通过动态模块生成驱动请求，生命周期管理与可观测性不稳定。
- 事件契约为松散 map，难以支持跨模块、跨 UI 的长期演进。
- `prompt / steering / follow-up` 的职责分散在 Session 与 Strategy 两层，存在重复队列语义。

目标状态是通用 AI Agent 平台，不是仅面向 coding 的单场景系统。平台需要支持：
- 多 Agent 协作（Coordinator/Orchestrator/Worker）
- multi-session workspaces（会话隔离与生命周期管理）
- two-tier memory（short-term + long-term）
- 多端 UI（CLI/Web/Native）统一接入

约束：
- 技术栈保持 Elixir + OTP + `jido/jido_ai`。
- 现有 CLI 能力在重构后需保持行为兼容，基于基线测试与回归验证保障稳定性。
- coding 能力保留为默认能力包，但平台本身不能绑定 coding 域。

## Goals / Non-Goals

**Goals:**
- 建立平台内核分层（runtime kernel、session/workspace、agent orchestration、memory、event contract）。
- 将单会话执行升级为受监督的 multi-session workspace 模型。
- 支持多 Agent 角色协作，并提供面向通用场景的能力编排。
- 定义 two-tier memory 架构与统一会话消息存储（conversation/event store）。
- 定义统一 client contract，保障 CLI/Web/Native 的接入一致性。
- 消除 Session 与 Strategy 双重排队，统一队列与中断语义。

**Non-Goals:**
- 本次变更不直接交付完整 Web UI 或 Native UI，仅定义与实现其接入 contract。
- 不在本次中完成所有 domain-specific tool packs，只建立可插拔机制与默认包。
- tool packs 的发布平台、版本管理与 capability registry 不在本次范围内。
- 不引入分布式集群调度与跨节点一致性方案（先单节点稳定化）。
- 不替换 `jido/jido_ai` 为自研 agent runtime。

## Decisions

### Decision 1: 采用平台化监督树，明确核心子系统边界
- 选择：在 `Prehen.Application` 下引入稳定监督拓扑，拆分为 `AgentSupervisor`、`SessionManager/SessionSupervisor`、`MemorySupervisor`、`ConversationStore`、`EventProjection`。
- 原因：将运行时、会话、记忆、事件存储从单体流程中解耦，便于独立扩展与故障隔离。

建议拓扑（概念）：

```text
Prehen.Application (one_for_one)
├─ Prehen.JidoRuntime
├─ Prehen.Agent.Supervisor
│  ├─ Coordinator AgentServer
│  └─ Orchestrator AgentServer
├─ Prehen.Workspace.SessionManager (GenServer)
├─ Prehen.Workspace.SessionSupervisor (DynamicSupervisor)
├─ Prehen.Memory.Supervisor
│  ├─ STM components
│  └─ LTM adapters
├─ Prehen.Conversation.Store
└─ Prehen.Events.ProjectionSupervisor
```

### Decision 2: Queue 所有权统一到 Session/Workspace 编排层
- 选择：`prompt / steering / follow-up` 的排队、优先级与中断控制全部由 Session 编排层负责；ReAct Strategy 仅处理单回合执行。
- 原因：消除双重排队语义，降低行为歧义，便于多端入口统一接入。

### Decision 3: 多 Agent 编排采用 Coordinator + Orchestrator + Worker 模式
- 选择：Coordinator 负责入口路由与会话关联；Orchestrator 负责任务编排与能力选择；Worker Agent 执行具体任务（工具调用、知识检索、对话生成等）。路由决策接口保持可插拔，允许规则驱动、模型驱动或混合策略并存。
- 原因：兼顾通用场景扩展、职责清晰与策略演进弹性，避免“单超级 Agent”变为不可维护黑盒。

### Decision 4: 事件与消息采用“typed event contract + canonical store”
- 选择：定义 `Prehen.Events.*` 事件模块（typed payload），统一 envelope 字段；会话消息落入 `Conversation.Store` 作为 canonical source，再投影到 UI/日志/指标。
- 原因：统一事件语义后，CLI/Web/Native 都可按同一 contract 订阅；也为审计、回放、调试提供基础。

事件 envelope（最小集合）：
- `type`, `at_ms`, `source`
- `session_id`, `request_id`, `run_id`, `turn_id`
- 可选 `agent_id`, `call_id`, `parent_call_id`, `workspace_id`
- `schema_version`（用于兼容）

### Decision 5: two-tier memory 采用“session-local STM + pluggable LTM adapter”
- 选择：
  - STM：每 session 维护短期上下文（conversation buffer、working context、token budget）。
  - LTM：本次仅定义通用 memory 行为接口（adapter contract），不实现具体检索与存储逻辑；接口可支持本地或远端后端。
- 原因：先稳定 two-tier memory 的边界与调用点，避免在架构重构阶段同时引入高不确定性的存储实现，并避免过早绑定单一存储类型。

### Decision 6: 工具能力改为可插拔 tool packs，coding pack 仅为默认包
- 选择：将工具组织为可注册的 capability pack（例如 `coding`, `knowledge`, `productivity`, `integration`），由 Orchestrator 基于会话策略选择。
- 原因：平台定位是通用助手，必须避免工具层与 coding 强绑定。

### Decision 7: 对外 client contract 统一，先稳定 CLI 再扩展 Web/Native
- 选择：抽象 `Client Surface` 层，统一提供会话生命周期 API、消息提交 API、事件订阅 API；CLI 作为第一个客户端实现。Web/Native 初期采用事件总线直连方式接入，后续如需要再引入 API Gateway。
- 原因：提前定义多端契约，避免后续 Web/Native 接入时反向改内核，并保持早期接入路径最短。

### Decision 8: 采用一次性重构切换到新架构
- 选择：在同一重构周期内完成内核与入口切换，不引入长期 compat mode；`trace_json` 直接升级到新结构，不保留历史版本兼容层。
- 原因：减少双轨维护成本，避免旧路径长期滞留导致架构腐化，并在当前无历史兼容包袱时一次性收敛契约。

## Risks / Trade-offs

- [监督树扩展后启动链路复杂，故障定位难度上升] → Mitigation：先定义明确的 child contracts 与健康检查事件，按子系统分层日志。
- [多 Agent 编排增加调度开销，响应时延上升] → Mitigation：引入任务分级与短路径策略（简单请求可走单 Agent fast path）。
- [`trace_json` 一次性升级导致内部调试脚本/工具失效] → Mitigation：在切换前统一更新内部消费者，并在发布检查中覆盖 `trace_json` 解析用例。
- [STM/LTM 引入后状态一致性复杂度提升] → Mitigation：先采用“STM 主、LTM 补充”的读取策略，明确写入顺序与失败降级路径。
- [tool packs 过于灵活导致权限边界模糊] → Mitigation：在 workspace 级别引入 capability allowlist 与权限策略。
- [一次性切换导致回归风险集中爆发] → Mitigation：先冻结 CLI 基线与回归测试，在发布前完成全链路压测与关键场景验收。

## Migration Plan

1. Step 0（基线冻结）
   - 冻结现有 CLI 行为基线与关键测试。
   - 定义新事件 envelope 与 `schema_version`。

2. Step 1（重构开发）
   - 在同一重构分支完成 runtime kernel、multi-session workspace、event/conversation store、multi-agent orchestration。
   - 接入 STM 与 LTM adapter contract（仅接口，不落地具体 LTM 存储逻辑）。
   - 固化 client contract，确保 CLI/Web/Native 可复用同一会话与事件接口（Web/Native 初期直连接入）。

3. Step 2（一次性切换）
   - 将默认执行路径切换为新架构，旧路径不再作为运行时双轨入口。
   - 发布前完成全链路回归、关键场景验收与性能对比，确认行为兼容。

Rollback 策略：
- 发布后如出现严重稳定性问题，按版本回滚到上一个稳定版本。
- 不在同一版本内维持长期 compat mode，避免双轨分叉。

## Confirmed Decisions

- `workspace` 支持多会话并发，不与 `session` 一一绑定。
- LTM 默认 adapter 接口抽象为通用 memory contract，可对接本地或远端实现。
- 多 Agent 路由保持策略接口灵活性，支持规则驱动、模型驱动与混合模式。
- `trace_json` 在本次重构中一次性升级到位，不提供历史版本兼容层。
- Web/Native 客户端初期采用直连接入，后续再按需求引入 API Gateway。
- tool packs 当前不引入发布与版本管理机制，待规模化需求出现后再补齐。
