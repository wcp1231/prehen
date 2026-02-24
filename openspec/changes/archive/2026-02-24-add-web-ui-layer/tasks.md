## 1. Phoenix 依赖与基础设施

- [x] 1.1 在 `mix.exs` 中添加 Phoenix 相关依赖（`phoenix`、`phoenix_pubsub`、`bandit`、`cors_plug`）
- [x] 1.2 创建 `lib/prehen_web/endpoint.ex`，配置 HTTP 和 WebSocket 监听
- [x] 1.3 创建 `lib/prehen_web/router.ex`，定义 `/api` scope 和路由管道（JSON pipeline）
- [x] 1.4 创建 `lib/prehen_web/channels/user_socket.ex`，声明 `"session:*"` Channel 路由
- [x] 1.5 在 `config/config.exs`、`config/dev.exs`、`config/runtime.exs` 中添加 Phoenix Endpoint 配置（端口默认 4000、CORS、WebSocket 路径）
- [x] 1.6 在 `Prehen.Application` supervision tree 中添加 `PrehenWeb.Endpoint` 子进程

## 2. EventSerializer

- [x] 2.1 创建 `lib/prehen_web/serializers/event_serializer.ex` 模块
- [x] 2.2 实现 `serialize/1` 纯函数，处理 tuple（`{:ok, v}` / `{:error, r}`）→ map 转换
- [x] 2.3 实现 atom → string、pid → 移除、嵌套 map/list 递归转换
- [x] 2.4 编写 EventSerializer 单元测试，覆盖所有转换规则和边界情况

## 3. REST Controllers

- [x] 3.1 创建 `lib/prehen_web/controllers/session_controller.ex`，实现 `create`、`index`、`show`、`delete` actions
- [x] 3.2 实现 `replay` action（`GET /api/sessions/:id/replay`），委托 `Client.Surface.replay_session/2` 并通过 EventSerializer 序列化事件列表
- [x] 3.3 创建 `lib/prehen_web/controllers/agent_controller.ex`，实现 `index` action 列出可用 agent 模板
- [x] 3.4 实现统一 JSON 错误格式（`FallbackController` 或 `ErrorJSON`），处理 404、422、400 等错误响应
- [x] 3.5 在 `router.ex` 中注册所有 REST 路由
- [ ] 3.6 编写 REST API controller 测试

## 4. SessionChannel

- [x] 4.1 创建 `lib/prehen_web/channels/session_channel.ex`，实现 `join/3`（验证 session 存在、subscribe_events、Process.monitor）
- [x] 4.2 实现 `handle_in("submit", payload, socket)`，委托 `Client.Surface.submit_message/3` 并回复 ack
- [x] 4.3 实现 `handle_info({:session_event, record}, socket)`，通过 EventSerializer 序列化后 `push(socket, "event", payload)`
- [x] 4.4 实现重连补缺逻辑：join 时检测 `last_seq` 参数，调用 `replay_session` 过滤 `seq > last_seq` 后逐个 push
- [x] 4.5 实现 `handle_info({:DOWN, ...}, socket)`，推送 `session.crashed` 或 `session.ended` 事件
- [ ] 4.6 编写 SessionChannel 测试（join、submit、事件推送、重连补缺、进程监控）

## 5. 应用启动方式更新

- [x] 5.1 更新 `Prehen.Application.start/2`，Phoenix Endpoint 默认启动（不再仅 CLI 模式）
- [x] 5.2 移除 `mix.exs` 中 escript 配置，启动方式改为 `mix phx.server` 或 OTP release
- [x] 5.3 确认 `mix phx.server` 或 OTP release 方式能正确启动完整 supervision tree

## 6. 前端项目初始化

- [x] 6.1 在项目根目录创建 `frontend/` 目录，使用 Bun 初始化 React 项目（`bun create vite frontend --template react-ts`）
- [x] 6.2 安装核心依赖：`phoenix`（Channel 客户端）、`react-router`、`zustand`
- [x] 6.3 配置 Vite 开发服务器代理，将 `/api` 和 `/socket` 请求代理到 Phoenix Endpoint（端口 4000）

## 7. 前端 Channel 连接与状态管理

- [x] 7.1 创建 `frontend/src/lib/socket.ts`，封装 Phoenix Socket 连接与自动重连逻辑
- [x] 7.2 创建 `frontend/src/lib/channel.ts`，封装 Channel join、leave、事件监听，管理 `last_seq`
- [x] 7.3 创建 `frontend/src/stores/sessionStore.ts`（Zustand），定义 session 状态结构（messages、toolCalls、status、lastSeq）
- [x] 7.4 实现事件分发器：按 `type` 字段将 `"event"` 消息路由到对应 state updater（delta → appendText、tool.call → addToolCall、turn.completed → finalizeMessage 等）

## 8. 前端 UI 组件

- [x] 8.1 创建 `frontend/src/components/ChatView.tsx`，实现消息列表渲染与 streaming 文本追加效果
- [x] 8.2 创建 `frontend/src/components/MessageInput.tsx`，实现消息输入与提交
- [x] 8.3 创建 `frontend/src/components/ToolViewer.tsx`，实现 tool 调用卡片（工具名、参数、loading 状态、结果展示）
- [x] 8.4 创建 `frontend/src/components/ThinkingBlock.tsx`，实现可折叠的 thinking 过程展示
- [x] 8.5 创建 `frontend/src/components/SessionList.tsx`，实现 session 列表展示与创建入口
- [x] 8.6 创建 `frontend/src/components/SessionPage.tsx`，组合 ChatView + MessageInput + ToolViewer

## 9. 前端路由与页面集成

- [x] 9.1 配置 React Router：`/` → SessionList，`/session/:id` → SessionPage
- [x] 9.2 实现 session 创建流程：选择 agent → POST /api/sessions → 跳转到 /session/:id
- [x] 9.3 实现 session 恢复流程：从列表点击 → 获取 replay 事件重建 UI → Channel join
- [x] 9.4 处理 WebSocket 断线重连：自动 rejoin 并通过 `last_seq` 补缺事件

## 10. 端到端集成验证

- [x] 10.1 验证完整流程：创建 session → 发送消息 → 接收 streaming delta → tool 调用可视化 → 轮次完成
- [x] 10.2 验证重连场景：手动断开 WebSocket → 重连 → 确认事件补缺正确
- [x] 10.3 验证错误场景：使用不存在的 agent 创建 session、session 崩溃时前端提示
- [x] 10.4 验证多轮对话：在同一 session 中连续发送多条消息，确认消息边界正确
