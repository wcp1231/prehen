## ADDED Requirements

### Requirement: Phoenix Endpoint 启动与配置
系统 MUST 在 Application supervision tree 中启动 `PrehenWeb.Endpoint`，提供 HTTP 和 WebSocket 服务。Endpoint MUST 支持通过配置文件指定监听端口（默认 4000），且 MUST 配置 CORS 以允许 SPA 跨域访问。

#### Scenario: 默认端口启动
- **WHEN** 系统启动且未显式配置端口
- **THEN** `PrehenWeb.Endpoint` SHALL 在端口 4000 上监听 HTTP 和 WebSocket 连接

#### Scenario: 自定义端口启动
- **WHEN** 系统配置文件或环境变量中指定了自定义端口
- **THEN** `PrehenWeb.Endpoint` SHALL 在指定端口上监听

#### Scenario: CORS 预检请求
- **WHEN** 前端 SPA 从不同 origin 发起 OPTIONS 预检请求
- **THEN** 系统 SHALL 返回正确的 CORS 响应头，允许后续跨域请求

### Requirement: Session REST API
系统 MUST 暴露 RESTful JSON API 以管理 session 生命周期，所有接口 SHALL 委托给 `Client.Surface` 对应方法。

#### Scenario: 创建 session
- **WHEN** 客户端发送 `POST /api/sessions` 并包含 `{"agent": "<name>"}` 请求体
- **THEN** 系统 SHALL 调用 `Client.Surface.create_session/1` 并返回 `201` 状态码与 `{"session_id": "<id>"}` 响应体

#### Scenario: 创建 session 失败
- **WHEN** 客户端发送 `POST /api/sessions` 且 agent 模板不存在
- **THEN** 系统 SHALL 返回 `422` 状态码与统一错误结构

#### Scenario: 列出 sessions
- **WHEN** 客户端发送 `GET /api/sessions`
- **THEN** 系统 SHALL 返回当前 workspace 下所有 session 的列表

#### Scenario: 查询 session 状态
- **WHEN** 客户端发送 `GET /api/sessions/:id`
- **THEN** 系统 SHALL 返回该 session 的当前状态信息

#### Scenario: 停止 session
- **WHEN** 客户端发送 `DELETE /api/sessions/:id`
- **THEN** 系统 SHALL 调用 `Client.Surface.stop_session/1` 并返回 `204` 状态码

#### Scenario: 回放 session 历史
- **WHEN** 客户端发送 `GET /api/sessions/:id/replay`
- **THEN** 系统 SHALL 调用 `Client.Surface.replay_session/2` 并返回该 session 的历史事件列表

### Requirement: Agent 列表 API
系统 MUST 暴露 API 以列出可用的 agent 模板。

#### Scenario: 获取 agent 列表
- **WHEN** 客户端发送 `GET /api/agents`
- **THEN** 系统 SHALL 返回当前配置中所有可用 agent 模板的名称与描述

### Requirement: 统一 JSON 错误响应
所有 REST API 错误响应 MUST 使用统一的 JSON 结构 `{"error": {"type": "<type>", "message": "<msg>"}}`。

#### Scenario: 请求不存在的 session
- **WHEN** 客户端发送 `GET /api/sessions/:id` 且该 session 不存在
- **THEN** 系统 SHALL 返回 `404` 状态码与统一错误结构

#### Scenario: 请求体格式错误
- **WHEN** 客户端发送请求且 JSON 请求体无法解析
- **THEN** 系统 SHALL 返回 `400` 状态码与统一错误结构
