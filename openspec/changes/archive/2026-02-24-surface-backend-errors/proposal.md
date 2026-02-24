## Why

后端错误（如 LLM 429 限流、模型回退失败等）虽然会触发 `ai.request.failed` 事件并通过 Channel 推送到前端，但用户在 UI 中看不到有意义的错误信息。原因有两层：EventSerializer 将错误结构（Elixir tuple/复杂 map）转换为 JSON 时丢失了关键信息；前端 `handleRequestFailed` 仅做了最低限度的文本拼接，没有专门的错误展示机制。

## What Changes

- 改进 `EventSerializer` 对错误场景的序列化策略，使 `ai.request.failed` 事件携带结构化、人类可读的错误描述
- 在前端 Message 模型中增加 `error` 字段，区分正常回复与错误消息
- 新增 `ErrorBanner` 组件，在对话流中以醒目样式展示错误（错误类型 + 用户可理解的描述）
- `handleRequestFailed` 从 payload 中提取结构化错误信息并正确更新状态

## Capabilities

### New Capabilities

_（无）_

### Modified Capabilities

- `event-serialization`：增加对 `ai.request.failed` 事件 `error` 字段的结构化序列化规则，确保错误原因（类型、HTTP 状态码、消息）在 JSON 中可读
- `react-spa-frontend`：Message 模型增加 `error` 字段；新增 `ErrorBanner` 组件；`handleRequestFailed` 提取并展示结构化错误

## Impact

- **后端**：`EventSerializer` 新增 `normalize_error/1` 辅助函数，仅影响序列化层，不改变事件产生逻辑
- **前端**：`Message` 接口增加可选 `error` 字段；新增 `ErrorBanner.tsx` 组件；`ChatView` 渲染逻辑增加错误分支；`sessionStore.ts` 的 `handleRequestFailed` 更新
- **不涉及**：Session、LLM Stream、Conversation Store 等核心模块无需修改——事件已正确产生，问题仅在序列化和展示层
