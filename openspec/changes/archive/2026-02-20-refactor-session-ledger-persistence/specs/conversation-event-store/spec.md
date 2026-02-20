## ADDED Requirements

### Requirement: 持久化先于投影发布
系统 MUST 先将记录成功持久化到 session ledger，再向 projection 总线发布该记录。

#### Scenario: 写入并投影事件
- **WHEN** 会话写入一条新记录
- **THEN** 系统 SHALL 先完成 `<session_id>.jsonl` 追加写入，再执行 publish

### Requirement: 回合完成持久化检查点
系统 MUST 在回合完成边界执行 durability checkpoint。

#### Scenario: 回合完成事件写入
- **WHEN** 系统写入回合完成记录
- **THEN** 系统 SHALL 对 ledger 执行同步刷盘，确保回合边界数据已持久化

## MODIFIED Requirements

### Requirement: Canonical Conversation/Event Store
系统 MUST 提供统一的 canonical conversation/event store 作为会话事实源，并以每 session 一个 `session_id.jsonl` 文件持久化存储。

#### Scenario: 写入会话消息与事件
- **WHEN** 会话产生用户消息、模型响应或工具执行事件
- **THEN** 系统 SHALL 以统一结构写入对应 session 的持久化 ledger

### Requirement: 事件追加写入与回放
系统 MUST 支持事件 append-only 写入与按条件回放，并且回放 SHALL 可在系统重启后基于持久化 ledger 工作，用于调试、审计与重建上下文。

#### Scenario: 按 session 回放事件
- **WHEN** 客户端请求回放某个 `session_id` 的历史
- **THEN** 系统 SHALL 按时间顺序返回该会话的历史消息与事件

#### Scenario: 重启后回放事件
- **WHEN** 系统重启后客户端请求回放某个历史 `session_id`
- **THEN** 系统 SHALL 从 `<session_id>.jsonl` 返回可用历史记录而非空结果
