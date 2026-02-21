## MODIFIED Requirements

### Requirement: Canonical Conversation/Event Store
系统 MUST 提供统一的 canonical conversation/event store 作为会话事实源，并在进程绑定的 workspace 下以 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl` 持久化存储。

#### Scenario: 写入会话消息与事件
- **WHEN** 会话产生用户消息、模型响应或工具执行事件
- **THEN** 系统 SHALL 以统一结构写入绑定 workspace 的 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl`

#### Scenario: 使用默认 workspace 路径
- **WHEN** 进程未显式指定 workspace 并写入会话记录
- **THEN** 系统 SHALL 将记录写入 `$HOME/.prehen/workspace/.prehen/sessions/<session_id>.jsonl`
