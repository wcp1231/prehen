## Purpose

React SPA 前端 -- 基于 Zustand 状态管理和 Phoenix Channel 实时通信的对话式 AI 交互界面，提供 session 管理、多轮对话、streaming 渲染和 tool 调用可视化。

## Requirements

### Requirement: Phoenix Channel 连接管理
前端 MUST 通过 `phoenix` npm 包与 Phoenix Endpoint 建立 WebSocket 连接，并管理 Channel 的 join、leave、重连生命周期。

#### Scenario: 建立 WebSocket 连接
- **WHEN** 前端应用启动并需要与后端通信
- **THEN** 前端 SHALL 创建 `Socket` 实例连接到 Phoenix Endpoint 的 WebSocket 路径

#### Scenario: 自动重连
- **WHEN** WebSocket 连接意外断开
- **THEN** 前端 SHALL 通过 `phoenix` 包的内置重连机制自动恢复连接，并以 `last_seq` 参数 rejoin Channel 以补缺事件

### Requirement: 事件驱动的状态管理
前端 MUST 使用 Zustand 管理会话状态，通过 Channel 接收的 `"event"` 消息按 `type` 字段分发到对应的 state updater。

#### Scenario: 接收 streaming delta
- **WHEN** 前端收到 `type: "ai.llm.delta"` 事件
- **THEN** 前端 SHALL 将 `delta` 字段的增量文本追加到当前消息内容，实现实时打字效果

#### Scenario: 接收 tool call 事件
- **WHEN** 前端收到 `type: "ai.tool.call"` 事件
- **THEN** 前端 SHALL 在当前消息中创建一个 tool 调用可视化条目，展示 `tool_name` 和 `arguments`，状态标记为 running

#### Scenario: 接收 tool result 事件
- **WHEN** 前端收到 `type: "ai.tool.result"` 事件
- **THEN** 前端 SHALL 根据 `call_id` 找到对应的 tool 调用条目，更新其状态为 completed 并展示 `result`

#### Scenario: 轮次完成
- **WHEN** 前端收到 `type: "ai.session.turn.completed"` 事件
- **THEN** 前端 SHALL 结束当前 assistant 消息的 streaming 状态，将消息标记为完成，并记录 `seq` 用于后续重连

#### Scenario: 接收 request failed 事件
- **WHEN** 前端收到 `type: "ai.request.failed"` 事件
- **THEN** 前端 SHALL 将 `error` 对象（`{ code, message, details? }`）写入当前 assistant 消息的 `error` 字段，标记消息为非 streaming，并在 UI 中渲染 `ErrorBanner` 组件展示错误

### Requirement: Session 管理界面
前端 MUST 提供 session 管理能力，包括创建新 session、查看 session 列表、恢复历史 session。

#### Scenario: 创建新 session
- **WHEN** 用户在界面中选择 agent 并点击创建
- **THEN** 前端 SHALL 调用 `POST /api/sessions` 获取 `session_id`，然后通过 Channel join 该 session

#### Scenario: 查看 session 列表
- **WHEN** 用户打开 session 列表
- **THEN** 前端 SHALL 调用 `GET /api/sessions` 并展示所有 session 的状态信息

#### Scenario: 恢复历史 session
- **WHEN** 用户从列表中选择一个历史 session
- **THEN** 前端 SHALL 调用 `GET /api/sessions/:id/replay` 获取历史事件并重建对话界面，然后通过 Channel join 该 session 以接收新事件

### Requirement: 多轮对话界面
前端 MUST 提供对话界面支持多轮交互，包括消息输入、消息历史展示、streaming 渲染。

#### Scenario: 发送消息
- **WHEN** 用户在输入框中输入文本并提交
- **THEN** 前端 SHALL 通过 Channel 发送 `"submit"` 事件，并在界面中追加一条用户消息

#### Scenario: 展示 assistant 回复（streaming）
- **WHEN** 前端接收到一系列 `ai.llm.delta` 事件
- **THEN** 前端 SHALL 逐步渲染 assistant 消息文本，呈现实时打字效果

#### Scenario: 展示 thinking 过程
- **WHEN** 前端接收到 `ai.react.step` 事件且 `phase` 为 `"thought"`
- **THEN** 前端 SHALL 在 assistant 消息中以可折叠区域展示 thinking 内容

### Requirement: Tool 调用可视化
前端 MUST 在对话流中可视化展示 tool 的调用过程和结果。

#### Scenario: 展示 tool 调用中
- **WHEN** 前端收到 `ai.tool.call` 事件
- **THEN** 前端 SHALL 在对话流中渲染 tool 调用卡片，展示工具名称和参数，并带有 loading 状态指示

#### Scenario: 展示 tool 调用结果
- **WHEN** 前端收到 `ai.tool.result` 事件
- **THEN** 前端 SHALL 更新对应 tool 卡片为完成状态，展示结果内容（成功或失败）

#### Scenario: 多个 tool 调用
- **WHEN** 一个 turn 中产生多个 tool 调用
- **THEN** 前端 SHALL 按 `call_id` 分别渲染每个 tool 调用卡片，各自独立展示状态和结果

### Requirement: 前端路由
前端 MUST 使用 React Router 管理页面路由。

#### Scenario: session 对话页面
- **WHEN** 用户导航到 `/session/:id` 路径
- **THEN** 前端 SHALL 加载对应 session 的对话界面

#### Scenario: session 列表页面
- **WHEN** 用户导航到 `/` 或 `/sessions` 路径
- **THEN** 前端 SHALL 展示 session 列表与创建入口

### Requirement: 错误消息展示
前端 MUST 在收到 `ai.request.failed` 事件时，以醒目的错误样式在对话流中展示结构化错误信息，并与正常 assistant 回复在视觉上明确区分。

#### Scenario: 接收 ai.request.failed 事件
- **WHEN** 前端收到 `type: "ai.request.failed"` 事件，payload 包含 `error: { code, message, details? }`
- **THEN** 前端 SHALL 将 `error` 对象存入当前 assistant 消息的 `error` 字段，将消息标记为非 streaming 状态，并在 UI 中渲染错误展示组件

#### Scenario: 部分 streaming 内容后出错
- **WHEN** 前端已通过 `ai.llm.delta` 接收到部分 streaming 文本，随后收到 `ai.request.failed` 事件
- **THEN** 前端 SHALL 保留已有 `content` 文本，同时展示 `error` 错误信息；两者在 UI 中同时可见

#### Scenario: 错误消息视觉区分
- **WHEN** 对话流中渲染包含 `error` 字段的消息
- **THEN** 前端 SHALL 以红色左边框 + 浅红背景的 banner 样式展示错误，包含错误 `code` 和 `message`，与正常 assistant 回复的样式明确不同

#### Scenario: 错误详情展开
- **WHEN** 错误包含 `details` 字段
- **THEN** 前端 SHALL 提供可折叠的详情区域，用户可展开查看完整错误上下文（如 model 名称、HTTP 状态码等调试信息）
