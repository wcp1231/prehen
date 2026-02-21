## MODIFIED Requirements

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
