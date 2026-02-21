## Purpose

定义 session ledger 持久化与恢复能力的规范，作为会话历史事实源与重启恢复流程的基线。

## Requirements

### Requirement: Session Ledger 文件持久化
系统 MUST 为每个 session 维护独立 append-only ledger 文件，文件名格式为 `<session_id>.jsonl`，并将其作为该 session 的 canonical facts source。

#### Scenario: 会话产生新事件与消息
- **WHEN** 会话产生用户消息、assistant 消息、toolcall 或执行事件
- **THEN** 系统 SHALL 将标准化记录追加写入对应的 `<session_id>.jsonl`

### Requirement: Ledger 存储目录与最小权限
系统 MUST 将 ledger 默认存储在 `$HOME/.prehen/workspace/.prehen/sessions`，并采用最小权限策略（目录 `0700`、文件 `0600`）；当进程绑定了自定义 workspace 时 SHALL 使用 `$WORKSPACE_DIR/.prehen/sessions`。

#### Scenario: 首次写入新 session（默认 workspace）
- **WHEN** 系统首次写入某个 `session_id` 的 ledger 且进程使用默认 workspace
- **THEN** 系统 SHALL 在 `$HOME/.prehen/workspace/.prehen/sessions` 创建目录与文件并设置最小权限

#### Scenario: 首次写入新 session（自定义 workspace）
- **WHEN** 系统首次写入某个 `session_id` 的 ledger 且进程绑定 `/projects/ws-a`
- **THEN** 系统 SHALL 在 `/projects/ws-a/.prehen/sessions` 创建目录与文件并设置最小权限

### Requirement: 历史 Session 恢复
系统 MUST 支持在系统重启后按 `session_id` 从当前进程绑定 workspace 的 ledger 路径恢复会话，使其可继续历史对话。

#### Scenario: 系统重启后继续历史对话
- **WHEN** 客户端请求恢复某个历史 `session_id`
- **THEN** 系统 SHALL 在当前绑定 workspace 下重放 `<session_id>.jsonl` 并恢复会话状态后继续接收新消息

#### Scenario: 绑定 workspace 中不存在目标 ledger
- **WHEN** 客户端请求恢复某个 `session_id` 且当前绑定 workspace 下无对应 ledger 文件
- **THEN** 系统 SHALL 返回恢复失败错误并拒绝继续该 session

### Requirement: 回合级 durability checkpoint
系统 MUST 以“每回合同步”作为默认 durability checkpoint 策略。

#### Scenario: 回合完成
- **WHEN** 系统写入 `ai.session.turn.completed` 或等价回合完成记录
- **THEN** 系统 SHALL 对对应 ledger 执行同步刷盘（例如 `:file.sync/1`）

### Requirement: Ledger 损坏硬失败
系统 MUST 在恢复阶段对损坏 ledger 执行硬失败，不得静默忽略损坏记录。

#### Scenario: 读取到损坏 ledger
- **WHEN** 系统在恢复 `session_id` 时发现 JSONL 结构损坏或序列不合法
- **THEN** 系统 SHALL 返回恢复失败错误并拒绝继续该 session，且输出可诊断错误信息

### Requirement: STM 通过回合摘要重建
系统 MUST 定义可重放的回合摘要记录，以支持从 ledger 重建 STM。

#### Scenario: 执行 STM 重建
- **WHEN** 系统执行 `session_id` 恢复并需要重建 STM
- **THEN** 系统 SHALL 按回合摘要记录顺序重建 `conversation_buffer`、`working_context` 与 `token_budget`
