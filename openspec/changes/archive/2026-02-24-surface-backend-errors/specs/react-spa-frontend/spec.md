## ADDED Requirements

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

## MODIFIED Requirements

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
