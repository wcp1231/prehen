## 1. EventSerializer 错误结构化

- [x] 1.1 在 `event_serializer.ex` 中新增 `normalize_error/1` 私有函数，处理以下模式：结构化 map（含 `:code` 键）、`{:model_fallback_exhausted, %{...}}` tuple、`{:await_crash, reason}` tuple、`{:cancelled, :steering}` tuple、`:timeout` 等简单 atom、fallback 分支
- [x] 1.2 修改 `serialize/1`，当事件 `type` 为 `"ai.request.failed"` 时，对 `error` 字段调用 `normalize_error/1` 替换通用转换
- [x] 1.3 编写 `normalize_error/1` 单元测试，覆盖设计文档中的转换规则表（6 种输入形态）

## 2. 前端 Message 模型扩展

- [x] 2.1 在 `sessionStore.ts` 的 `Message` 接口中增加 `error?: { code: string; message: string; details?: unknown }` 可选字段
- [x] 2.2 修改 `handleRequestFailed`：从 `payload.error` 提取结构化错误对象写入 `msg.error`，不再拼接到 `msg.content`；保留已有 `content` 不清空

## 3. ErrorBanner 组件

- [x] 3.1 创建 `frontend/src/components/ErrorBanner.tsx`，接收 `{ code: string; message: string; details?: unknown }` props，渲染红色左边框 + 浅红背景 banner，展示 code 和 message
- [x] 3.2 实现 details 可折叠展开：当 `details` 存在时，提供展开按钮显示 JSON 格式化的详情
- [x] 3.3 在 `index.css` 中添加 ErrorBanner 样式（`.error-banner`、`.error-banner-details`）

## 4. ChatView 集成

- [x] 4.1 修改 `ChatView.tsx`，在 assistant 消息渲染逻辑中增加 `msg.error` 检测：当 `error` 存在时，在消息内容（content / toolCalls / thinking）之后渲染 `ErrorBanner`
- [x] 4.2 确保 partial content + error 场景：消息同时有 `content` 和 `error` 时，两者都渲染

## 5. 验证

- [x] 5.1 `mix compile` 通过
- [x] 5.2 `mix test test/prehen_web/serializers/event_serializer_test.exs` 通过（含新增测试）
- [x] 5.3 `cd frontend && bun run build` 通过
