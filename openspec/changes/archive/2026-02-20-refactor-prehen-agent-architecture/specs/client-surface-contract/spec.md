## ADDED Requirements

### Requirement: 统一多端会话 API
系统 MUST 为 CLI、Web、Native 暴露统一会话生命周期 API（创建、提交消息、状态查询、停止）。

#### Scenario: 不同客户端调用同一会话接口
- **WHEN** CLI 与 Web 客户端分别调用创建与提交消息接口
- **THEN** 系统 SHALL 使用一致的请求结构与返回结构处理两端请求

### Requirement: 统一事件订阅契约
系统 MUST 提供统一事件订阅 API，并定义标准事件 envelope 与类型语义。

#### Scenario: 客户端订阅会话事件流
- **WHEN** 客户端按 `session_id` 订阅事件
- **THEN** 系统 SHALL 返回包含标准 envelope 字段的事件序列

### Requirement: 直连接入优先
系统 MUST 支持 Web/Native 客户端在当前阶段通过事件总线直连接入，不强依赖 API Gateway。

#### Scenario: Web 客户端直连订阅
- **WHEN** Web 客户端直接连接事件总线并订阅某会话
- **THEN** 系统 SHALL 在不引入额外网关层的前提下提供可用订阅能力

### Requirement: MVP 阶段认证鉴权后置
系统 MUST 将客户端认证与鉴权机制标记为后续增强项，不作为 MVP 直连接入的发布前置条件。

#### Scenario: MVP 客户端接入
- **WHEN** Web/Native 客户端在 MVP 阶段接入会话与事件接口
- **THEN** 系统 SHALL 允许按既定 contract 直连接入，并将认证与鉴权实现纳入后续迭代计划

### Requirement: 请求关联字段一致性
系统 MUST 在客户端请求与事件响应中保持关联字段一致，以支持端到端追踪。

#### Scenario: 客户端提交消息并接收事件
- **WHEN** 客户端发送一次 `prompt` 请求并开始接收事件
- **THEN** 系统 SHALL 在请求回执与后续事件中保持 `session_id` 与 `request_id` 一致

### Requirement: 统一错误与超时语义
系统 MUST 定义统一错误结构与超时行为，避免不同客户端出现歧义。

#### Scenario: 客户端请求超时
- **WHEN** 消息提交请求超过配置超时阈值
- **THEN** 系统 SHALL 返回统一超时错误结构并附带可追踪标识
