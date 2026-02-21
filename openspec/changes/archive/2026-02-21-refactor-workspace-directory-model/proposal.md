## Why

当前系统将 `workspace_id`（逻辑标识）、`root_dir`（工具根目录）与 `session_ledger_dir`（持久化目录）分离配置，导致 workspace 语义割裂，用户难以理解“Agent 管理数据”与“用户业务数据”的边界。需要收敛为单一物理 workspace 目录模型，统一 Agent 元数据、会话持久化与工具访问根边界。

## What Changes

- 引入物理 `workspace` 目录模型：`$WORKSPACE_DIR/.prehen/` 作为 Agent 专用资源区，包含 `config/`、`sessions/`、`memory/`、`plugins/`、`tools/`、`skills/`；`$WORKSPACE_DIR` 其余部分存放用户希望 Agent 管理的数据。
- 默认 workspace 目录设为 `$HOME/.prehen/workspace`，并要求同样遵循上述目录结构。
- 引入全局资源目录 `$HOME/.prehen/global/`（`config/`、`plugins/`、`tools/`、`skills/`），并定义“workspace 优先、global 回退”的同名资源覆盖规则。
- CLI 保留 `--workspace` 参数，但语义改为“workspace 物理路径”。
- 移除 `root_dir` 相关参数与配置，统一使用 `workspace` 目录作为工具访问根目录。
- 明确允许 tools 访问 `$WORKSPACE_DIR/.prehen`，支持 Agent 自主管理元数据与资源。
- Session ledger 路径统一为 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl`，memory 相关文件路径统一归入 `$WORKSPACE_DIR/.prehen/memory/`。
- 运行时约束调整为“一个 Prehen 进程只绑定一个 workspace”；需要多个 workspace 时通过多个进程分别管理。
- **BREAKING**：移除逻辑 `workspace_id` 的控制面语义与对外 contract（会话创建、恢复、状态等接口不再接受/返回 `workspace_id`）。
- **BREAKING**：移除 `root_dir`（含 CLI 参数与环境变量）并统一切换到 `workspace` 根目录边界。
- **BREAKING**：`--workspace` 参数语义从逻辑 ID 改为物理路径。

## Capabilities

### New Capabilities
- `workspace-directory-layout`: 定义 workspace 目录结构、`.prehen` 专用资源区、global 回退机制与资源覆盖优先级。
- `single-workspace-runtime-binding`: 定义单进程单 workspace 绑定语义，以及 workspace 不匹配时的错误行为。

### Modified Capabilities
- `cli-react-agent-runtime`: CLI 参数语义更新为 `--workspace` 传物理路径，移除 `root_dir`。
- `client-surface-contract`: 会话相关 contract 去除 `workspace_id` 输入输出，按进程绑定 workspace 运作。
- `conversation-event-store`: 事件持久化目录从独立配置收敛到 `$WORKSPACE_DIR/.prehen/sessions`。
- `session-ledger-recovery`: 恢复流程基于 workspace 绑定路径解析 ledger，不再基于逻辑 `workspace_id` 选择目录。
- `multi-session-workspaces`: 从“同进程多 workspace_id 隔离”调整为“单 workspace 进程内多 session 隔离”。
- `local-fs-tools`: 工具根目录统一为 `workspace`，并明确允许访问 `.prehen` 子目录。

## Impact

- 受影响模块：`Prehen.CLI`、`Prehen.Config`、`Prehen.Agent.Runtime`、`Prehen.Client.Surface`、`Prehen.Workspace.SessionManager`、`Prehen.Actions.PathGuard`、`Prehen.Actions.LS`、`Prehen.Actions.Read`、`Prehen.Conversation.SessionLedger`、`Prehen.Conversation.Store`。
- 配置与环境变量影响：新增/统一 `workspace` 路径配置；移除 `root_dir` 相关配置；ledger 路径由 workspace 派生。
- API/契约影响：会话接口与状态结构去除 `workspace_id` 字段；CLI `--workspace` 参数语义变更为路径。
- 运行部署影响：每个 Prehen 进程固定绑定一个 workspace，管理多个 workspace 需要多进程部署。
