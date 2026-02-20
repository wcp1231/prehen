## ADDED Requirements

### Requirement: STM 重建输入契约
系统 MUST 定义可用于 STM 重建的回合摘要输入契约，并保证恢复流程可消费该契约。

#### Scenario: 执行 STM 重建
- **WHEN** 系统读取某 `session_id` 的 ledger 并执行恢复
- **THEN** 系统 SHALL 基于回合摘要按顺序重建 `conversation_buffer`、`working_context` 与 `token_budget`

### Requirement: LTM 与 Session Ledger 职责隔离
系统 MUST 将 LTM 与 session 历史事实流职责隔离，LTM SHALL NOT 作为会话历史恢复的必需依赖。

#### Scenario: 会话恢复时 LTM 不可用
- **WHEN** 系统恢复某历史 session 且 LTM adapter 不可用
- **THEN** 系统 SHALL 仍可基于 ledger 完成 STM 重建并继续会话

## MODIFIED Requirements

### Requirement: Session 级 STM 管理
系统 MUST 为每个 session 维护独立 short-term memory（STM），包括对话缓冲、工作上下文与 token 预算；STM SHALL 作为内存态工作集，并可由持久化 ledger 重建。

#### Scenario: 会话执行中更新 STM
- **WHEN** 会话完成一次回合并产生新消息与工具 observation
- **THEN** 系统 SHALL 将新增上下文写入该 session 的 STM 并更新预算状态

#### Scenario: 系统重启后恢复 STM
- **WHEN** 系统重启并恢复某历史 `session_id`
- **THEN** 系统 SHALL 通过 ledger 回放重建该 session 的 STM 状态

### Requirement: Memory 读取策略
系统 MUST 采用“STM 主、LTM 补充”的读取策略，保证短期上下文优先；若会话由恢复路径进入，系统 SHALL 先完成 STM 重建再执行读取拼装。

#### Scenario: 生成回合上下文
- **WHEN** 系统为下一轮推理组装上下文
- **THEN** 系统 SHALL 先读取 STM，再按策略补充 LTM 结果

#### Scenario: 恢复后首次读取上下文
- **WHEN** 某历史 session 恢复完成并发起首轮推理
- **THEN** 系统 SHALL 基于已重建 STM 执行上下文读取，并按策略补充 LTM

### Requirement: Memory 写入顺序与降级
系统 MUST 明确 memory 写入顺序，并在 LTM 失败时保证会话可继续；LTM 失败 SHALL NOT 影响 session ledger 持久化与恢复能力。

#### Scenario: LTM 写入失败
- **WHEN** 会话结束回合后 LTM 写入返回错误
- **THEN** 系统 SHALL 保留 STM 更新结果并记录失败事件，而不阻塞会话后续执行

#### Scenario: LTM 不可用但会话恢复
- **WHEN** LTM adapter 不可用且系统恢复某历史 session
- **THEN** 系统 SHALL 继续完成会话恢复并允许对话续接
