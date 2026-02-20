## ADDED Requirements

### Requirement: 历史会话恢复 API 契约
系统 MUST 提供统一的历史会话恢复 API，并返回与创建会话一致的最小标识信息（如 `session_id`、`workspace_id`、运行句柄）。

#### Scenario: 客户端恢复历史会话
- **WHEN** 客户端调用恢复接口并指定历史 `session_id`
- **THEN** 系统 SHALL 返回统一结构的恢复结果，供后续 `submit_message` 与 `await_result` 复用

## MODIFIED Requirements

### Requirement: 统一多端会话 API
系统 MUST 为 CLI、Web、Native 暴露统一会话生命周期 API（创建、恢复、提交消息、状态查询、停止）。

#### Scenario: 不同客户端调用同一会话接口
- **WHEN** CLI 与 Web 客户端分别调用创建/恢复与提交消息接口
- **THEN** 系统 SHALL 使用一致的请求结构与返回结构处理两端请求

### Requirement: 请求关联字段一致性
系统 MUST 在客户端请求与事件响应中保持关联字段一致，以支持端到端追踪；恢复历史 session 时 SHALL 继续使用原 `session_id`。

#### Scenario: 客户端提交消息并接收事件
- **WHEN** 客户端发送一次 `prompt` 请求并开始接收事件
- **THEN** 系统 SHALL 在请求回执与后续事件中保持 `session_id` 与 `request_id` 一致

#### Scenario: 恢复会话后的关联字段
- **WHEN** 客户端恢复某历史 `session_id` 并继续提交消息
- **THEN** 系统 SHALL 在后续回执与事件中继续输出同一 `session_id`

### Requirement: 统一错误与超时语义
系统 MUST 定义统一错误结构与超时行为，避免不同客户端出现歧义；恢复场景下 ledger 损坏 SHALL 返回统一恢复失败错误结构。

#### Scenario: 客户端请求超时
- **WHEN** 消息提交请求超过配置超时阈值
- **THEN** 系统 SHALL 返回统一超时错误结构并附带可追踪标识

#### Scenario: 恢复时 ledger 损坏
- **WHEN** 客户端请求恢复某 `session_id` 且系统检测到 ledger 损坏
- **THEN** 系统 SHALL 返回统一错误结构并明确恢复失败原因
