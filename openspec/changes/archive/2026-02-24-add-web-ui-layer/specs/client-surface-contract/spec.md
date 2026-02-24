## ADDED Requirements

### Requirement: 事件 payload 的 JSON 序列化兼容性
`Client.Surface` 的事件订阅 contract 所产出的事件 payload MUST 在经过 `EventSerializer` JSON 序列化后保持业务字段的可辨识性。Core 层在事件中 SHALL NOT 引入无法通过递归转换处理的 Elixir 专有类型（如 function、reference），以保证 Channel 消费路径的兼容性。

#### Scenario: Channel 进程作为事件订阅者
- **WHEN** Phoenix Channel 进程通过 `subscribe_events/1` 订阅 session 事件
- **THEN** 系统 SHALL 以 `{:session_event, record}` 消息格式将事件投递到 Channel 进程的 mailbox，与其他订阅者行为一致

#### Scenario: 事件 payload 经过序列化后字段可识别
- **WHEN** Channel 进程收到事件并经过 `EventSerializer.serialize/1` 转换
- **THEN** 转换后的 JSON map SHALL 保留 `type`、`session_id`、`seq`、`at_ms` 等 envelope 字段，且业务字段（如 `delta`、`tool_name`、`arguments`、`result`）SHALL 可被前端正确解析

### Requirement: Session pid 到 session_id 的双向查找
Channel 在 WebSocket 重连场景下 MUST 能够通过 `session_id` 重新获取 session 进程。`Client.Surface` 的 `resume_session/2` MUST 支持此场景，返回可用的 `session_pid`。

#### Scenario: Channel 重连后通过 session_id 恢复 pid
- **WHEN** 前端 WebSocket 重连，Channel 进程以 `session_id` 重新 join
- **THEN** Channel SHALL 通过 `Client.Surface.resume_session/2` 获取该 session 的新 pid 引用，并重新建立事件订阅与进程监控
