## ADDED Requirements

### Requirement: 多 Agent 角色边界
系统 MUST 提供 `Coordinator`、`Orchestrator`、`Worker` 三类 Agent 角色，并保持职责边界清晰。

#### Scenario: 请求进入平台后完成角色分工
- **WHEN** 客户端提交新任务到平台入口
- **THEN** 系统 SHALL 由 `Coordinator` 负责会话关联，由 `Orchestrator` 负责任务编排，并由 `Worker` 执行具体动作

### Requirement: 编排路由策略可插拔
系统 MUST 提供可插拔的编排路由接口，支持规则驱动、模型驱动与混合策略。

#### Scenario: 切换路由策略实现
- **WHEN** workspace 配置从规则驱动切换为模型驱动
- **THEN** 系统 SHALL 在不修改会话 API 与事件契约的前提下完成路由策略切换

### Requirement: 任务分发与回收
系统 MUST 支持将任务分解并分发到多个 Worker，并在完成后回收为单一可消费结果。

#### Scenario: 多 Worker 并行执行子任务
- **WHEN** Orchestrator 将一个请求拆分为多个可并行子任务
- **THEN** 系统 SHALL 跟踪每个子任务状态并在全部完成或超时后汇总结果返回上层

### Requirement: 失败隔离与降级
系统 MUST 在单个 Worker 失败时保证会话与其他 Worker 不被级联中断，并支持降级路径。

#### Scenario: 单 Worker 执行失败
- **WHEN** 某个 Worker 在工具调用阶段返回错误
- **THEN** 系统 SHALL 仅标记该子任务失败并允许 Orchestrator 执行重试、替代或部分结果返回策略

### Requirement: 跨 Agent 关联追踪
系统 MUST 为跨 Agent 任务链路输出统一关联字段，保证可观测性与可审计性。

#### Scenario: 生成跨 Agent 追踪事件
- **WHEN** 请求在 Coordinator、Orchestrator 与 Worker 间流转
- **THEN** 系统 SHALL 在事件中包含 `session_id`、`request_id`、`run_id`、`turn_id` 与可用的 `agent_id`、`parent_call_id`
