## Requirements

### Requirement: secret_ref 引用解析
系统 MUST 支持通过 `secret_ref` 从 `secrets.yaml` 解析密钥值，并将解析结果注入运行时请求参数。

#### Scenario: Provider API Key 引用解析成功
- **WHEN** `providers.yaml` 中凭证字段声明 `secret_ref: providers.openai_official.api_key`
- **THEN** 系统 SHALL 从 `secrets.yaml` 中解析该路径并用于该 Provider 的请求认证

### Requirement: secrets 解析优先级
系统 MUST 采用 `workspace secrets > global secrets` 的解析优先级。

#### Scenario: workspace 与 global 存在同名 secret
- **WHEN** workspace 与 global 的 `secrets.yaml` 都存在 `providers.openai_official.api_key`
- **THEN** 系统 SHALL 选择 workspace secret 值

### Requirement: secrets 单树结构
系统 MUST 使用单一 secrets 配置树，且 SHALL NOT 要求按环境（如 `dev/test/prod`）分段配置。

#### Scenario: 未提供环境分段字段
- **WHEN** `secrets.yaml` 仅包含单层配置树且未声明 `dev/test/prod`
- **THEN** 系统 SHALL 正常完成 secret 解析与运行

### Requirement: secret_ref 错误语义
系统 MUST 在 `secret_ref` 解析失败时返回稳定错误语义，供调用方诊断与处理。

#### Scenario: secret_ref 路径不存在
- **WHEN** `secret_ref` 指向的路径在 workspace/global secrets 中均不存在
- **THEN** 系统 SHALL 返回 `secret_ref_not_found` 错误并拒绝启动相关调用

#### Scenario: secret 值类型无效
- **WHEN** `secret_ref` 解析到非字符串值
- **THEN** 系统 SHALL 返回 `secret_value_invalid` 错误并拒绝启动相关调用
