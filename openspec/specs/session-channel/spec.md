## Purpose

Phoenix Channel 会话通道 -- 以 `session:<id>` 为 topic 的实时双向通信通道，负责事件订阅、消息提交、重连补缺和 session 进程生命周期监控。

## Requirements

### Requirement: Channel Topic 与 Join 语义
系统 MUST 支持前端通过 Phoenix Channel 以 `"session:<session_id>"` 为 topic 加入会话的事件流。Join 时 Channel 进程 MUST 调用 `Client.Surface.subscribe_events/1` 注册为该 session 的事件订阅者，并调用 `Process.monitor/1` 监控 session 进程。

#### Scenario: 加入已有 session
- **WHEN** 前端以 topic `"session:<session_id>"` 加入 Channel 且该 session 存在
- **THEN** Channel MUST 订阅该 session 的事件流，监控 session 进程，并返回 `{:ok, %{"session_id" => session_id}}`

#### Scenario: 加入不存在的 session
- **WHEN** 前端以不存在的 `session_id` 加入 Channel
- **THEN** Channel MUST 返回 `{:error, %{"reason" => "session_not_found"}}`

### Requirement: 消息提交
Channel MUST 支持前端通过 `handle_in("submit", payload)` 提交用户消息，并委托给 `Client.Surface.submit_message/3`。

#### Scenario: 提交 prompt 消息
- **WHEN** 前端发送 `"submit"` 事件，payload 为 `{"text": "你好", "kind": "prompt"}`
- **THEN** Channel MUST 调用 `submit_message` 并回复 `{:reply, {:ok, %{"request_id" => id}}, socket}`

#### Scenario: 提交 follow_up 消息
- **WHEN** 前端发送 `"submit"` 事件，payload 为 `{"text": "继续", "kind": "follow_up"}`
- **THEN** Channel MUST 以 `follow_up` 类型提交消息

#### Scenario: 提交消息时 session 已结束
- **WHEN** 前端发送 `"submit"` 事件但 session 进程已终止
- **THEN** Channel MUST 回复 `{:reply, {:error, %{"reason" => "session_unavailable"}}, socket}`

### Requirement: 统一事件推送
Channel MUST 将所有来自 `{:session_event, record}` 的事件通过 `push(socket, "event", serialized)` 统一推送到前端。Channel SHALL NOT 对事件类型做映射或过滤，仅负责序列化和推送。

#### Scenario: 收到 streaming delta 事件
- **WHEN** Channel 进程收到 `{:session_event, %{type: "ai.llm.delta", ...}}`
- **THEN** Channel MUST 序列化该事件并通过 `push(socket, "event", payload)` 推送到前端

#### Scenario: 收到 tool call 事件
- **WHEN** Channel 进程收到 `{:session_event, %{type: "ai.tool.call", ...}}`
- **THEN** Channel MUST 序列化该事件并通过 `push(socket, "event", payload)` 推送到前端

#### Scenario: 新增事件类型
- **WHEN** Core 层新增一种事件类型且 Channel 未做任何修改
- **THEN** 新事件 SHALL 自动通过统一 `"event"` push 到达前端

### Requirement: 重连事件补缺
Channel MUST 支持前端在 rejoin 时通过 `last_seq` 参数补缺断线期间丢失的事件。

#### Scenario: 带 last_seq 重连
- **WHEN** 前端以 `{"last_seq": 42}` 参数 rejoin Channel
- **THEN** Channel MUST 调用 `Client.Surface.replay_session/2` 获取历史事件，过滤出 `seq > 42` 的记录，逐个序列化并 push 到前端，然后切换到实时订阅

#### Scenario: 无 last_seq 首次加入
- **WHEN** 前端不携带 `last_seq` 参数加入 Channel
- **THEN** Channel MUST 跳过回放，直接订阅实时事件流

### Requirement: Session 进程异常通知
Channel MUST 在监控到 session 进程终止时向前端推送异常事件。

#### Scenario: session 进程崩溃
- **WHEN** Channel 监控的 session 进程异常退出
- **THEN** Channel MUST 向前端 push `{"type": "session.crashed", "reason": "<reason>"}` 事件

#### Scenario: session 正常完成
- **WHEN** session 进程正常退出（如所有 turn 完成且空闲超时后清理）
- **THEN** Channel MUST 向前端 push `{"type": "session.ended"}` 事件
