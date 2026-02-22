## MODIFIED Requirements

### Requirement: 统一多端会话 API
系统 MUST 为 CLI、Web、Native 暴露统一会话生命周期 API（创建、恢复、提交消息、状态查询、停止），并支持通过 Agent 模板名称驱动执行配置。

#### Scenario: 客户端按 Agent 模板创建并执行会话
- **WHEN** 客户端在创建会话或一站式运行入口中提供 `agent` 名称
- **THEN** 系统 SHALL 解析对应模板并使用模板配置处理后续消息执行

#### Scenario: 客户端提供未知 Agent 模板
- **WHEN** 客户端提供不存在的 `agent` 名称
- **THEN** 系统 SHALL 返回统一错误结构并标识 `agent_template_not_found`

### Requirement: 统一错误与超时语义
系统 MUST 在模板解析失败、密钥引用失败、模型回退耗尽等场景下返回统一错误结构，避免不同客户端出现歧义。

#### Scenario: 模板存在但 secret_ref 缺失
- **WHEN** 客户端调用使用某 Agent 模板，且模板所依赖的 `secret_ref` 无法解析
- **THEN** 系统 SHALL 返回统一错误结构并包含 `secret_ref_not_found` 诊断原因

#### Scenario: 模型回退链耗尽
- **WHEN** 主模型与所有 fallback 模型均执行失败
- **THEN** 系统 SHALL 返回统一错误结构并标识回退链已耗尽
