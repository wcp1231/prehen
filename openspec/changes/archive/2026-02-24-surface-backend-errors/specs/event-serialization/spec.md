## ADDED Requirements

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
