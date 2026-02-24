## Purpose

PrehenWeb.EventSerializer -- Elixir 内部事件结构到 JSON 安全 map 的纯函数转换层，确保 Channel 推送到前端的事件 payload 兼容 JSON 序列化。

## Requirements

### Requirement: Elixir 事件结构到 JSON 的安全转换
系统 MUST 提供 `PrehenWeb.EventSerializer` 模块，将 Elixir 内部事件 map 转换为 JSON 安全的 map。转换 MUST 是纯函数，不依赖外部状态。

#### Scenario: 包含 tuple 的事件
- **WHEN** 事件 payload 中包含 `{:ok, value}` 或 `{:error, reason}` tuple
- **THEN** serializer SHALL 将 `{:ok, value}` 转换为 `%{"status" => "ok", "value" => value}`，将 `{:error, reason}` 转换为 `%{"status" => "error", "reason" => inspect(reason)}`

#### Scenario: 包含 atom 的事件
- **WHEN** 事件 payload 中包含 atom 值（如 `:content`、`:completed`）
- **THEN** serializer SHALL 将 atom 转换为对应的字符串（如 `"content"`、`"completed"`）

#### Scenario: 包含 pid 的事件
- **WHEN** 事件 payload 中包含 Elixir pid（如 `session_pid`）
- **THEN** serializer SHALL 移除该字段，不将 pid 序列化到 JSON 输出中

#### Scenario: 嵌套 map 和 list
- **WHEN** 事件 payload 中包含嵌套的 map 或 list
- **THEN** serializer SHALL 递归遍历所有层级并对每个值应用相同的转换规则

#### Scenario: 基本类型透传
- **WHEN** 事件 payload 中包含 string、number、boolean、nil 等 JSON 原生类型
- **THEN** serializer SHALL 保持原样不做转换

### Requirement: 序列化后字段完整性
序列化后的 JSON map MUST 保留事件的所有 envelope 字段（`type`、`seq`、`session_id`、`at_ms`、`request_id`、`run_id`、`turn_id`），仅移除不可序列化的字段（如 pid）。

#### Scenario: envelope 字段保留
- **WHEN** 一条 `ai.llm.delta` 事件经过序列化
- **THEN** 输出 SHALL 包含 `type`、`seq`、`session_id`、`at_ms` 等 envelope 字段

#### Scenario: 未知字段透传
- **WHEN** Core 层在事件中新增了 serializer 未显式处理的字段
- **THEN** serializer SHALL 尝试递归转换该字段值，不丢弃未知字段

### Requirement: 错误字段结构化序列化
`EventSerializer` MUST 对 `ai.request.failed` 事件的 `error` 字段执行专用转换（`normalize_error/1`），将各类 Elixir 错误结构统一为 `%{"code" => string, "message" => string, "details" => map | nil}` 格式。此规则仅作用于 `error` 字段，不影响通用序列化逻辑。

#### Scenario: 结构化 map 错误
- **WHEN** `error` 字段为 map 且包含 `:code` 键（如 `%{code: :llm_stream_exception, error_type: :rate_limit, reason: "429 Too Many Requests"}`）
- **THEN** serializer SHALL 输出 `%{"code" => "llm_stream_exception", "message" => "429 Too Many Requests", "details" => %{"error_type" => "rate_limit"}}`

#### Scenario: 语义 tuple 错误（model_fallback_exhausted）
- **WHEN** `error` 字段为 `{:model_fallback_exhausted, %{reason: reason, model_error: model_error}}` tuple
- **THEN** serializer SHALL 输出 `%{"code" => "model_fallback_exhausted", "message" => <从 model_error 提取的可读描述>, "details" => %{"reason" => ..., "model_error" => ...}}`

#### Scenario: 语义 tuple 错误（await_crash）
- **WHEN** `error` 字段为 `{:await_crash, reason}` tuple
- **THEN** serializer SHALL 输出 `%{"code" => "await_crash", "message" => "Session process crashed", "details" => %{"reason" => inspect(reason)}}`

#### Scenario: 简单 atom 错误
- **WHEN** `error` 字段为单个 atom（如 `:timeout`）
- **THEN** serializer SHALL 输出 `%{"code" => "timeout", "message" => "Request timed out"}`

#### Scenario: 未知结构 fallback
- **WHEN** `error` 字段不匹配任何已知模式
- **THEN** serializer SHALL 输出 `%{"code" => "unknown", "message" => inspect(value)}`，确保不会因未知结构导致序列化崩溃
