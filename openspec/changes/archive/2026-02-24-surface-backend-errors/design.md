## Context

`ai.request.failed` 事件已在 Session 层正确产生并通过 Channel 推送到前端。但错误信息在两个环节丢失可读性：

1. **EventSerializer**：当 `error` 字段是 tuple（如 `{:model_fallback_exhausted, %{reason: ..., model_error: ...}}`），通用序列化规则将其转为 JSON 数组 `["model_fallback_exhausted", {...}]`，前端无法解析语义。Map 形式的错误（如 `%{code: :llm_stream_exception, ...}`）反而保留了结构。
2. **前端 handleRequestFailed**：仅做 `payload.error || "Request failed"` 文本拼接，无论后端传什么结构，用户看到的都是 `"Error: [object Object]"` 或空内容。

后端错误的来源形态有三类：
- **结构化 map**：`%{code: atom, error_type: atom, reason: term, model: string}` — 来自 `llm_stream.ex`
- **语义 tuple**：`{:model_fallback_exhausted, %{...}}`、`{:await_crash, reason}`、`{:cancelled, :steering}` — 来自 `session.ex`
- **简单 atom/string**：`:timeout`、`:jido_ai_not_available` — 各处

## Goals / Non-Goals

**Goals:**

- 用户在 UI 中能看到人类可读的错误描述（如 "Rate limit exceeded (429)"，而非 inspect 出的 Elixir 结构）
- 错误消息在对话流中有视觉区分（红色/警告色 banner），不与正常回复混淆
- 保留错误细节供调试（code、HTTP status、model 名称），同时提供简洁摘要

**Non-Goals:**

- 不改变 Session/LLM Stream 的错误产生逻辑——问题不在事件源
- 不做错误重试/恢复机制——本次只解决"看得到"的问题
- 不处理 Channel 层面的网络错误展示——那是 `session.crashed`/`onError` 的职责，已有机制

## Decisions

### D1: EventSerializer 增加 `normalize_error/1`，而非修改通用转换规则

在 `serialize/1` 中对 `ai.request.failed` 事件的 `error` 字段做特殊处理，调用 `normalize_error/1` 将各类错误统一为：

```elixir
%{
  "code" => "model_fallback_exhausted",    # 错误代码，machine-readable
  "message" => "Model fallback exhausted", # 人类可读摘要
  "details" => %{...}                      # 可选，额外上下文
}
```

**Why not 修改通用 tuple 转换规则？** 通用规则（tuple→list）服务于所有事件类型，改动影响面大。error 字段是唯一需要特殊语义的场景，专门处理更安全。

**转换规则：**

| 输入形态 | code | message | details |
|---------|------|---------|---------|
| `%{code: c, reason: r, ...}` (map) | `c` | 从 `r` 提取 | 其余字段 |
| `{:model_fallback_exhausted, %{reason: r, model_error: e}}` | `"model_fallback_exhausted"` | 从 `e` 提取 | `%{reason: r, model_error: e}` |
| `{:await_crash, reason}` | `"await_crash"` | `"Session process crashed"` | `%{reason: inspect(reason)}` |
| `{:cancelled, :steering}` | `"cancelled"` | `"Request cancelled by user"` | — |
| `:timeout` | `"timeout"` | `"Request timed out"` | — |
| 其他 | `"unknown"` | `inspect(value)` | — |

### D2: 前端 Message 增加 `error` 可选字段，而非复用 `content`

当前 `handleRequestFailed` 将错误写入 `msg.content`，导致：
- 错误和正常文本在渲染路径上无区分
- 先输出了部分 streaming 内容再出错时，错误信息被丢弃（`msg.content ||` 逻辑）

改为在 `Message` 接口上增加 `error?: { code: string; message: string; details?: unknown }`。`ChatView` 渲染时检测 `msg.error` 存在则渲染 `ErrorBanner`，否则正常渲染 `content`。

### D3: ErrorBanner 组件内联在 ChatView 消息列表中

不使用全局 toast/snackbar，因为错误与具体消息轮次相关。`ErrorBanner` 作为消息气泡的附属元素，紧跟在该轮次的已有内容（如 streaming 片段、tool call 卡片）之后。

样式：红色左边框 + 浅红背景 + 错误图标 + 可展开 details。

## Risks / Trade-offs

- **[未覆盖的错误形态]** → `normalize_error/1` 的 fallback 分支使用 `inspect()`，确保未知结构不会导致序列化崩溃，仅可读性降低
- **[partial content + error 共存]** → 设计允许一条消息同时有 `content`（已 streaming 的片段）和 `error`（失败原因），UI 两者都展示。Trade-off：用户可能困惑"为什么有半句话加一个错误"——但这比吞掉错误或吞掉已输出内容都好
