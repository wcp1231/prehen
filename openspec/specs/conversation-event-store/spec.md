## Requirements

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

### Requirement: Canonical Conversation/Event Store
系统 MUST 提供统一的 canonical conversation/event store 作为会话事实源，并在进程绑定的 workspace 下以 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl` 持久化存储。

#### Scenario: 写入会话消息与事件
- **WHEN** 会话产生用户消息、模型响应或工具执行事件
- **THEN** 系统 SHALL 以统一结构写入绑定 workspace 的 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl`

#### Scenario: 使用默认 workspace 路径
- **WHEN** 进程未显式指定 workspace 并写入会话记录
- **THEN** 系统 SHALL 将记录写入 `$HOME/.prehen/workspace/.prehen/sessions/<session_id>.jsonl`

### Requirement: Typed Event Envelope
系统 MUST 为事件定义 typed envelope，至少包含 `type`、`at_ms`、`source`、`session_id`、`request_id`、`run_id`、`turn_id` 与 `schema_version`。

#### Scenario: 生成标准事件包
- **WHEN** 运行时发出任意生命周期或执行事件
- **THEN** 系统 SHALL 输出符合 typed envelope 的结构并包含必需字段

### Requirement: 事件追加写入与回放
系统 MUST 支持事件 append-only 写入与按条件回放，并且回放 SHALL 可在系统重启后基于持久化 ledger 工作，用于调试、审计与重建上下文。

#### Scenario: 按 session 回放事件
- **WHEN** 客户端请求回放某个 `session_id` 的历史
- **THEN** 系统 SHALL 按时间顺序返回该会话的历史消息与事件

#### Scenario: 重启后回放事件
- **WHEN** 系统重启后客户端请求回放某个历史 `session_id`
- **THEN** 系统 SHALL 从 `<session_id>.jsonl` 返回可用历史记录而非空结果

### Requirement: 多投影消费
系统 MUST 支持将 canonical store 投影到 CLI 输出、日志与指标消费侧。

#### Scenario: 同一事件被多端消费
- **WHEN** 一条工具执行完成事件写入 canonical store
- **THEN** 系统 SHALL 支持 CLI 渲染与观测指标投影同时消费该事件

### Requirement: `trace_json` 一次性升级
系统 MUST 将 `trace_json` 一次性升级到新事件结构，不提供历史版本兼容层。

#### Scenario: 导出新版本 `trace_json`
- **WHEN** 客户端请求导出 `--trace-json`
- **THEN** 系统 SHALL 输出基于新 envelope 的结构，且 SHALL NOT 输出旧版字段映射
