## MODIFIED Requirements

### Requirement: Workspace 支持多会话并发
系统 MUST 支持单个已绑定 workspace 目录下并发运行多个 session。

#### Scenario: 同一绑定 workspace 并发创建多个 session
- **WHEN** 客户端在同一个进程绑定 workspace 下连续创建两个以上会话
- **THEN** 系统 SHALL 为每个会话分配独立 `session_id` 并允许并发执行

### Requirement: 历史 Session 恢复能力
系统 MUST 支持在当前进程绑定的 workspace 内按 `session_id` 恢复历史 session，并继续会话执行。

#### Scenario: 在绑定 workspace 中恢复历史 session
- **WHEN** 客户端请求恢复历史 `session_id`
- **THEN** 系统 SHALL 在当前绑定 workspace 中恢复对应会话并允许继续提交消息

### Requirement: 会话隔离与资源边界
系统 MUST 保证不同 session 之间的状态、队列、上下文与 ledger 文件严格隔离，且其 ledger 文件 SHALL 位于绑定 workspace 的 `.prehen/sessions` 目录中。

#### Scenario: 并发会话互不污染
- **WHEN** 两个 session 同时执行并接收不同消息队列
- **THEN** 系统 SHALL 确保任一 session 的消息、memory 与事件不会写入另一 session

#### Scenario: 持久化文件隔离
- **WHEN** 两个 session 分别写入历史记录
- **THEN** 系统 SHALL 将记录写入各自的 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl`，不得出现跨文件污染

#### Scenario: 显式 workspace 覆盖与绑定冲突
- **WHEN** 已绑定 workspace 的进程收到不同 workspace 路径的显式覆盖请求
- **THEN** 系统 SHALL 返回 `workspace_mismatch` 错误并保持现有会话不受影响
