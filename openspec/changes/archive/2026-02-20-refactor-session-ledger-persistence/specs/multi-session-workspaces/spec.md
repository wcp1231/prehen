## ADDED Requirements

### Requirement: 历史 Session 恢复能力
系统 MUST 支持在同一 workspace 内按 `session_id` 恢复历史 session，并继续会话执行。

#### Scenario: 在 workspace 中恢复历史 session
- **WHEN** 客户端在某 `workspace_id` 下请求恢复历史 `session_id`
- **THEN** 系统 SHALL 在该 workspace 中恢复对应会话并允许继续提交消息

### Requirement: 会话回收后保留 Ledger
系统 MUST 在 session 停止或空闲回收后保留对应 ledger 文件，以支持后续恢复。

#### Scenario: 空闲会话被回收
- **WHEN** 某 session 因空闲超时被回收
- **THEN** 系统 SHALL 仅释放运行时进程资源，不删除该 session 的持久化 ledger

## MODIFIED Requirements

### Requirement: Session 生命周期管理
系统 MUST 提供会话创建、启动、恢复、停止、状态查询与资源回收能力。

#### Scenario: 会话完整生命周期
- **WHEN** 客户端依次调用创建、执行、停止接口
- **THEN** 系统 SHALL 正确推进会话状态并在停止后释放会话级运行资源

#### Scenario: 历史会话恢复并继续执行
- **WHEN** 客户端调用恢复接口并指定历史 `session_id`
- **THEN** 系统 SHALL 恢复该会话的可执行状态并继续后续回合

### Requirement: SessionManager 仅承担 Control Plane 职责
系统 MUST 将 `SessionManager` 限定为控制面组件（生命周期编排、索引、恢复路由决策），不承载会话执行面的长时业务状态。

#### Scenario: 会话执行流转
- **WHEN** 会话进入回合执行并产生队列与运行状态变化
- **THEN** 系统 SHALL 由具体 session 进程维护执行状态，`SessionManager` 仅维护控制面元数据与调度指令

#### Scenario: 历史会话恢复流转
- **WHEN** 系统执行某历史 `session_id` 的恢复
- **THEN** 系统 SHALL 由 session 进程执行重放与状态重建，`SessionManager` 仅负责恢复入口与元数据编排

### Requirement: 会话隔离与资源边界
系统 MUST 保证不同 session 之间的状态、队列、上下文与 ledger 文件严格隔离。

#### Scenario: 并发会话互不污染
- **WHEN** 两个 session 同时执行并接收不同消息队列
- **THEN** 系统 SHALL 确保任一 session 的消息、memory 与事件不会写入另一 session

#### Scenario: 持久化文件隔离
- **WHEN** 两个 session 分别写入历史记录
- **THEN** 系统 SHALL 将记录写入各自的 `<session_id>.jsonl`，不得出现跨文件污染
