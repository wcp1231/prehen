## Why

Prehen 的产品目标已从单一 CLI ReAct MVP 扩展为通用 AI Agent 平台，需要支撑多 Agent 协作、multi-session workspaces、two-tier memory，以及 Web/Native 等多端 UI 接入。当前实现仍偏单 Agent 与单会话执行模型，无法稳定承载平台化演进，且与“通用助手”定位不一致，需尽快完成架构对齐。

## What Changes

- 将运行时从“单体 session 编排”升级为平台内核：明确 agent lifecycle、session lifecycle、orchestration 边界，并采用受监督的进程模型。
- 采用一次性重构切换策略：在同一重构周期内完成新架构切换，不引入长期 compat mode 双轨运行。
- 引入 multi-session workspace 能力，提供会话隔离、生命周期管理、状态查询与资源清理，并作为多端 UI 的统一工作空间抽象；`SessionManager` 仅承担 control plane 职责。
- 引入 multi-agent orchestration 能力，支持 Coordinator/Orchestrator/Worker 等角色化协作，且不绑定 coding 单一场景。
- 建立 two-tier memory（short-term + long-term）能力：本次仅实现 STM 与 LTM 接口边界，不实现具体 LTM 存储/检索逻辑。
- LTM 在本次以“接口兼容性/contract test（mock/stub adapters）”为验收方式，确保后续本地或远端后端可替换。
- 建立统一的事件与会话消息契约（signal/event + conversation store），确保跨 Agent、跨 Session、跨 UI 的可观测性和一致性。
- MVP 阶段 Web/Native 客户端先采用直连接入；认证与鉴权机制不在本次范围内，后续单独增强。
- 将工具能力从“coding 默认绑定”调整为“可插拔能力包（tool packs）”，保留 coding 能力作为默认包之一，但不作为平台唯一主路径。
- **BREAKING**: `trace_json` 与运行时事件结构将升级为统一契约，依赖旧字段/旧事件命名的调用方需要迁移。
- **BREAKING**: 运行时内部模块边界与进程拓扑将调整，依赖当前内部实现细节的扩展代码需要适配。

## Capabilities

### New Capabilities

- `multi-agent-orchestration`: 定义多 Agent 角色协作、请求路由、任务分发与回收机制，支持通用场景编排。
- `multi-session-workspaces`: 定义 workspace/session 的创建、隔离、生命周期管理与状态查询能力，并明确 `SessionManager` 的 control plane 边界。
- `two-tier-memory`: 定义 short-term memory 与 long-term memory 的接口契约、回填策略与兼容性验证方式（contract test）。
- `client-surface-contract`: 定义面向 CLI/Web/Native 的统一会话 API 与事件订阅契约，MVP 先支持直连接入。
- `conversation-event-store`: 定义 canonical conversation/event 存储与回放能力，支持跨会话追踪与审计。

### Modified Capabilities

- `cli-react-agent-runtime`: 从单 Agent CLI 执行语义升级为平台兼容运行时语义，调整事件、会话与执行边界定义。
- `local-fs-tools`: 将本地文件系统工具能力调整为可插拔 tool pack，明确其在通用平台中的边界与权限契约。

## Impact

- 受影响代码：
  - `lib/prehen.ex`
  - `lib/prehen/config.ex`
  - `lib/prehen/agent/runtime.ex`
  - `lib/prehen/agent/session.ex`
  - `lib/prehen/agent/backends/jido_ai.ex`
  - `lib/prehen/agent/session/adapters/jido_ai.ex`
  - `lib/prehen/agent/strategies/react_ext.ex`
  - `lib/prehen/agent/strategies/react_machine_ext.ex`
  - `lib/prehen/agent/event_bridge.ex`
- 预期新增或拆分模块：
  - `lib/prehen/application.ex`
  - `lib/prehen/agent/supervisor.ex`
  - `lib/prehen/agent/session_manager.ex`
  - `lib/prehen/agent/session_supervisor.ex`
  - `lib/prehen/agent/orchestrator/*`
  - `lib/prehen/agent/memory/*`
  - `lib/prehen/agent/events/*`
  - `lib/prehen/agent/conversation_store/*`
- 受影响接口与消费方：
  - CLI `--trace-json` 消费方（需迁移到新事件契约）
  - 未来 Web/Native 客户端的 session/event 订阅接口（MVP 直连，后续再引入认证鉴权）
  - `Prehen.start_session/stop_session/prompt/steer/follow_up/await_idle` 的行为时序与返回结构（以向后兼容为目标，trace 与内部状态字段除外）
- 测试与文档：
  - `test/prehen/agent/*` 需按多 Agent、多会话与事件契约重构
  - 需要新增跨 capability 集成测试（orchestration/session/memory）与 LTM contract tests（mock/stub adapters）
  - `design.md` 与 `tasks.md` 将按一次性切换策略对齐实现路径与发布门禁
