## Why

当前会话历史（对话、toolcall、trace）与 memory 职责边界不够清晰，且运行时主要依赖内存态数据，系统重启后无法恢复历史 session 并继续对话。随着 multi-session 与多轮交互场景增多，需要将“会话事实源持久化 + 可恢复”作为基础能力一次性落地，并明确 STM/LTM 的分工。

## What Changes

- 引入文件化 Session Ledger：以 `session_id.jsonl` 作为每个 session 的持久化事实流文件，统一记录会话消息、事件与 toolcall/toolresult 历史。
- 将 `Conversation.Store` 重构为围绕持久化 ledger 的统一读写/回放入口，保证 append-only 写入与按 session 回放。
- 新增 session 恢复能力：系统重启后可按 `session_id` 从 ledger 重放并恢复会话上下文，继续历史会话对话。
- 明确 `STM` 为内存态短期工作集（推理窗口/working context/token budget），其状态可由 ledger 重放恢复，不再承担历史事实源职责。
- 明确 `LTM` 为跨会话、跨任务的长期知识层（如用户偏好、常用工具），与 session 历史账本职责分离。
- **BREAKING**：不保留旧的“仅内存会话历史”行为与兼容路径，统一切换到 ledger-first 的会话数据模型。

## Capabilities

### New Capabilities
- `session-ledger-recovery`: 定义基于 `session_id.jsonl` 的会话事实持久化、重放恢复与续聊能力。

### Modified Capabilities
- `conversation-event-store`: 从内存 append/replay 扩展为文件持久化 ledger 语义，要求重启后可回放历史事件。
- `multi-session-workspaces`: 增加历史 session 的恢复与继续执行能力，扩展会话生命周期到“可恢复会话”场景。
- `two-tier-memory`: 明确 STM 为内存态工作集且可重建，LTM 为跨会话长期知识，不与 session 历史事实流重叠。
- `client-surface-contract`: 扩展会话 API contract 以支持恢复历史 session 与继续对话的统一调用语义。
- `cli-react-agent-runtime`: 调整 CLI 运行时的 session 绑定语义，使其可在指定 workspace 中恢复并续接历史 session。

## Impact

- 受影响模块：`Prehen.Conversation.Store`、`Prehen.Agent.Session`、`Prehen.Workspace.SessionManager`、`Prehen.Memory.STM`、`Prehen.Client.Surface`、`Prehen.Agent.Runtime`。
- 新增/调整存储约束：引入 session ledger 文件目录与 `session_id.jsonl` 文件管理、回放与恢复流程。
- API/契约影响：会话创建与继续对话语义将扩展为“新建或恢复”，事件回放来源统一为持久化 ledger。
- 运维与可靠性影响：重启后可恢复历史 session，诊断与审计能力提升；同时引入文件 IO、写入原子性与损坏恢复处理要求。
