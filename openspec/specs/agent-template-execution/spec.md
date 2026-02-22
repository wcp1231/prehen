## Requirements

### Requirement: Agent 模板配置契约
系统 MUST 支持 Agent 模板配置，并要求模板可声明 `name`、`description`、`system_prompt`、`capability_packs`、主模型与备用模型。

#### Scenario: 加载 Agent 模板
- **WHEN** `agents.yaml` 中定义了名为 `coder` 的模板并包含上述字段
- **THEN** 系统 SHALL 能按模板名称解析出可执行配置

### Requirement: Agent 模型参数配置
系统 MUST 支持在 Agent 模板中配置模型参数（如 `temperature`、`max_tokens`），并在执行时生效。

#### Scenario: Agent 模板覆盖模型默认参数
- **WHEN** Provider 模型声明了 `default_params` 且 Agent 模板为同一模型声明 `params`
- **THEN** 系统 SHALL 以 Agent `params` 覆盖 Provider 模型默认参数后执行请求

### Requirement: Agent 模板运行入口
系统 MUST 支持“指定 Agent 模板名称 + 输入”执行，并在模板不存在时返回统一错误。

#### Scenario: 通过模板名称运行
- **WHEN** 调用方提供 `agent: "coder"` 与用户输入
- **THEN** 系统 SHALL 加载 `coder` 模板并按模板配置完成执行

#### Scenario: 模板不存在
- **WHEN** 调用方提供不存在的 Agent 模板名称
- **THEN** 系统 SHALL 返回 `agent_template_not_found` 错误

### Requirement: 备用模型回退策略
系统 MUST 支持 Agent 级备用模型链，并基于 `on_errors` 规则选择是否切换。

#### Scenario: 主模型超时触发回退
- **WHEN** 主模型调用失败且错误类型匹配 `fallback_models[*].on_errors`
- **THEN** 系统 SHALL 切换到下一个备用模型继续执行

#### Scenario: 认证错误不自动回退
- **WHEN** 主模型失败为认证类错误（如 API key 无效）
- **THEN** 系统 SHALL 不自动切换备用模型并返回失败
