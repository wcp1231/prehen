## MODIFIED Requirements

### Requirement: 历史会话恢复 API 契约
系统 MUST 提供统一的历史会话恢复 API，并返回与创建会话一致的最小标识信息（如 `session_id`、运行句柄），且 SHALL NOT 返回 `workspace_id`。

#### Scenario: 客户端恢复历史会话
- **WHEN** 客户端调用恢复接口并指定历史 `session_id`
- **THEN** 系统 SHALL 返回统一结构的恢复结果，供后续 `submit_message` 与 `await_result` 复用，且不包含 `workspace_id`

### Requirement: 统一多端会话 API
系统 MUST 为 CLI、Web、Native 暴露统一会话生命周期 API（创建、恢复、提交消息、状态查询、停止），并以进程绑定 workspace 的方式运行。

#### Scenario: 不同客户端调用同一会话接口
- **WHEN** CLI 与 Web 客户端分别调用创建/恢复与提交消息接口
- **THEN** 系统 SHALL 使用一致的请求结构与返回结构处理两端请求，且不要求每次请求显式携带 workspace 参数

#### Scenario: 客户端显式覆盖不同 workspace
- **WHEN** 客户端在已绑定进程中显式传入与当前绑定不一致的 workspace 路径
- **THEN** 系统 SHALL 返回 `workspace_mismatch` 错误并拒绝该请求
