## ADDED Requirements

### Requirement: Workspace 支持多会话并发
系统 MUST 支持单个 workspace 下并发运行多个 session。

#### Scenario: 同一 workspace 并发创建多个 session
- **WHEN** 客户端在同一个 `workspace_id` 下连续创建两个以上会话
- **THEN** 系统 SHALL 为每个会话分配独立 `session_id` 并允许并发执行

### Requirement: Session 生命周期管理
系统 MUST 提供会话创建、启动、停止、状态查询与资源回收能力。

#### Scenario: 会话完整生命周期
- **WHEN** 客户端依次调用创建、执行、停止接口
- **THEN** 系统 SHALL 正确推进会话状态并在停止后释放会话级运行资源

### Requirement: SessionManager 仅承担 Control Plane 职责
系统 MUST 将 `SessionManager` 限定为控制面组件（生命周期编排、索引与路由决策），不承载会话执行面的长时业务状态。

#### Scenario: 会话执行流转
- **WHEN** 会话进入回合执行并产生队列与运行状态变化
- **THEN** 系统 SHALL 由具体 session 进程维护执行状态，`SessionManager` 仅维护控制面元数据与调度指令

### Requirement: 会话隔离与资源边界
系统 MUST 保证不同 session 之间的状态、队列与上下文严格隔离。

#### Scenario: 并发会话互不污染
- **WHEN** 两个 session 同时执行并接收不同消息队列
- **THEN** 系统 SHALL 确保任一 session 的消息、memory 与事件不会写入另一 session

### Requirement: 队列所有权归属 Session 编排层
系统 MUST 将 `prompt / steering / follow-up` 的排队与中断语义统一到 Session 编排层。

#### Scenario: steering 抢占同会话后续工具执行
- **WHEN** 会话处于回合执行中且 Session 队列收到高优先级 steering
- **THEN** 系统 SHALL 由 Session 编排层决定中断与续接行为，Strategy 层仅处理单回合执行

### Requirement: 会话空闲检测与清理
系统 MUST 支持会话空闲检测与可配置清理策略，以控制资源占用。

#### Scenario: 会话长时间空闲
- **WHEN** 某 session 超过配置的空闲阈值且无排队请求
- **THEN** 系统 SHALL 将其标记为可回收并执行会话资源清理流程
