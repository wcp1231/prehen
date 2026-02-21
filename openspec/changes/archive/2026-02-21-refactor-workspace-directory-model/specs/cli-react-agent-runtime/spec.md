## MODIFIED Requirements

### Requirement: CLI 恢复会话入口
系统 MUST 为 CLI 提供恢复历史 session 的显式入口，并支持在绑定 workspace 物理目录中恢复后继续同一会话执行。

#### Scenario: CLI 指定历史 session 继续对话
- **WHEN** 用户执行 `prehen run --workspace /projects/ws-1 --session-id <session_id> "继续这个任务"`
- **THEN** 系统 SHALL 在 `/projects/ws-1` 绑定目录中恢复对应会话，并在同一 `session_id` 下继续 ReAct 回合

#### Scenario: CLI 未显式提供 workspace 时恢复历史会话
- **WHEN** 用户执行 `prehen run --session-id <session_id> "继续这个任务"`
- **THEN** 系统 SHALL 在默认目录 `$HOME/.prehen/workspace` 下执行恢复流程

### Requirement: CLI 任务执行入口
系统 MUST 提供 CLI 命令入口以接收自然语言任务并触发平台化运行时执行流程，并支持在指定 workspace 物理目录下创建新 session 或恢复历史 session。

#### Scenario: 用户提交任务并绑定 workspace 路径
- **WHEN** 用户执行 `prehen run --workspace /projects/ws-1 "列出 lib 并读取 prehen.ex"`
- **THEN** 系统 SHALL 在 `/projects/ws-1` 下创建新会话并启动一次 ReAct 回合

#### Scenario: 用户恢复历史会话并继续任务
- **WHEN** 用户执行 `prehen run --workspace /projects/ws-1 --session-id s-123 "继续上次分析"`
- **THEN** 系统 SHALL 在 `/projects/ws-1` 下恢复 `s-123` 并继续执行新的回合

#### Scenario: 用户未提供 workspace 参数
- **WHEN** 用户执行 `prehen run "继续分析"` 且未提供 `--workspace`
- **THEN** 系统 SHALL 使用默认 workspace 路径 `$HOME/.prehen/workspace`

#### Scenario: 用户提供已移除参数
- **WHEN** 用户执行 `prehen run "任务" --root-dir ./tmp`
- **THEN** 系统 SHALL 将该输入视为无效参数并返回参数错误
