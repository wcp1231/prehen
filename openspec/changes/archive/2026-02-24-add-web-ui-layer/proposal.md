## Why

当前系统仅通过 CLI escript 提供单轮对话能力，只适用于简单测试场景。需要引入 Web UI 层以支持多轮对话、streaming 渲染、tool 调用可视化等交互体验，同时为后续 Tauri 2 桌面端复用同一套前端和 API 铺路。

## What Changes

- 新增 Phoenix Transport 层（`lib/prehen_web/`），提供 REST API 和 WebSocket Channel
- 新增 REST API 用于 session CRUD（创建、列表、状态查询、停止）和 agent 列表
- 新增 Phoenix Channel（`SessionChannel`）桥接 `Client.Surface` 的事件订阅，实时推送 `ai.llm.delta`、`ai.tool.call`、`ai.tool.result` 等事件到前端
- 新增 `EventSerializer` 模块，将 Elixir 内部事件（含 tuple/atom）序列化为 JSON 安全格式
- 新增 React SPA 前端（`frontend/`，使用 Bun），消费 REST + WebSocket API
- 前端实现 streaming 文本渲染、tool 调用可视化、多轮对话管理
- 引入 Phoenix、phoenix_pubsub、cors_plug 等依赖到 `mix.exs`

## Capabilities

### New Capabilities

- `phoenix-transport`: Phoenix Endpoint、Router、JSON API controller 层，将 `Client.Surface` 暴露为 HTTP REST + WebSocket 接口
- `session-channel`: Phoenix Channel 实现，负责会话事件的实时推送、统一 `"event"` push 格式、重连补缺（基于 `last_seq` + `replay_session`）、session 进程监控
- `event-serialization`: 事件序列化层，将 Elixir 内部事件结构（tuple、atom、嵌套 map）转换为 JSON 安全的前端可消费格式
- `react-spa-frontend`: React SPA 前端应用，包含 Phoenix Channel 客户端集成、streaming 渲染、tool 可视化组件、session 管理界面

### Modified Capabilities

- `client-surface-contract`: Channel 场景下 `subscribe_events` 的消费者从 CLI projection 扩展到 Channel 进程；需确认事件 payload 在 JSON 序列化后的字段完整性

## Impact

- **依赖**: `mix.exs` 新增 `phoenix`、`phoenix_pubsub`、`phoenix_live_dashboard`（可选）、`cors_plug`、`jason`（已有）
- **代码**: 新增 `lib/prehen_web/` 目录（endpoint、router、channel、controller、serializer）
- **前端**: 新增 `frontend/` 目录（React + Bun 工程）
- **配置**: 新增 Phoenix endpoint 配置（端口、CORS、WebSocket 路径）到 `config/`
- **Application**: supervision tree 需加入 `PrehenWeb.Endpoint`
- **部署**: 从纯 escript 扩展为 release（Phoenix 需要 OTP release），CLI escript 路径保持兼容
