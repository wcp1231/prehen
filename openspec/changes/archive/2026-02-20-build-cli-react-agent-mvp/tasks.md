## 1. MVP 基线（已完成）

- [x] 1.1 接入 `jido`、`jido_ai`、`req_llm` 并打通 CLI + ReAct + `ls/read` 基本链路
- [x] 1.2 完成本地只读工具安全边界（路径规范化、根目录限制、读取长度限制）
- [x] 1.3 完成基础测试与 README 说明，确保 `prehen run "<task>"` 可用

## 2. Session-Oriented 入口与状态

- [x] 2.1 引入 Session API，支持三类输入：`prompt`、`steering`、`follow-up`
- [x] 2.2 在 ReAct strategy/machine 扩展状态字段：`prompt_q/steer_q/followup_q`、`turn_phase`、`pending_tool_calls`
- [x] 2.3 将运行驱动从单次调用升级为“入队 + state machine step”推进

## 3. Steering / Follow-Up 基础版（先落地）

- [x] 3.1 基于现有信号实现 steering：`ai.react.cancel` + 高优先级 query 注入
- [x] 3.2 基于现有生命周期信号实现 follow-up：请求完成后串行追加下一条 query
- [x] 3.3 明确并实现中断语义：未执行工具返回 skipped observation（`"Skipped due to queued user message"`）

## 4. Signal 事件契约标准化

- [x] 4.1 统一采用 `ai.request.* / ai.llm.* / ai.tool.* / ai.react.step / ai.session.*`
- [x] 4.2 对所有关键事件注入 correlation 字段：`session_id/request_id/run_id/turn_id/call_id`
- [x] 4.3 增加 `event_bridge`（或等价层）将 signal 投影为 CLI 可消费的结构化事件流

## 5. 流式消息与中断收敛

- [x] 5.1 实现 `partial_message` 占位管理：`ai.llm.delta` 增量更新，`ai.llm.response` 转最终消息
- [x] 5.2 处理中断收敛：partial 有内容保留入历史；为空则丢弃并上报 aborted
- [x] 5.3 统一 `cancel/timeout/error` 的回合结束状态，避免脏状态残留

## 6. 完整版增强与回归

- [x] 6.1 扩展 ReAct strategy/machine，补齐 steering/follow-up 专用信号路由与 pending 队列
- [x] 6.2 增加工具链“逐步中断检查”与 skipped tool result 注入
- [x] 6.3 增加可插拔策略：`retry_policy`、`model_router`
- [x] 6.4 补齐集成测试：并发输入、连续 follow-up、取消竞争、信号断言与回归测试
