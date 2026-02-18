## Context

项目当前是空白 Elixir 骨架，未具备 Agent 编排、模型调用、工具注册与运行入口。  
本次变更目标是用最小复杂度交付一个可工作的通用 AI Agent MVP：
- 仅 CLI 入口
- 单 Agent
- ReAct 执行策略
- 工具仅 `ls` 与 `read`
- 模型接入使用 `req_llm`
- Agent 基础逻辑使用 `jido + jido_ai`

约束：
- 优先可运行与可验证，不追求完整平台能力
- 保持模块边界清晰，避免后续扩展时重构成本过高
- 保障本地工具调用的最小安全边界

## Goals / Non-Goals

**Goals:**
- 在命令行中执行自然语言任务，并驱动 Agent 完成多步推理与工具调用。
- 建立可扩展的运行时骨架：LLM Adapter、Tool Registry、ReAct Loop。
- 提供 `ls`/`read` 两个稳定、可测试、受限的本地工具。
- 提供结构化执行追踪，支持定位失败点与行为回放。

**Non-Goals:**
- 不实现多 Agent 协作。
- 不实现 Web UI / HTTP API。
- 不实现长期记忆（向量库、数据库）。
- 不实现通用 shell 执行工具。
- 不实现自动代码写入与自动执行外部命令。

## Decisions

### 1) 仅 CLI 作为 MVP 交互层
- 选择：优先实现 `prehen run "<task>"`。
- 原因：最短路径验证核心能力，减少接口面和部署复杂度。
- 备选：
  - CLI + HTTP API：扩展性更好，但超出 MVP 交付速度目标。

### 2) 使用 ReAct 单循环而非 Plan-and-Execute
- 选择：采用 `think -> action -> observation -> finish` 的循环模型。
- 原因：实现简单、可解释性强，便于快速调试与建立可观测性。
- 备选：
  - Plan-and-Execute：在复杂任务上更稳定，但需要额外规划器与状态管理。

### 3) 运行时分层：Orchestrator / LLM Adapter / Tool Registry
- 选择：将 Agent 循环与模型调用、工具执行解耦。
- 原因：降低耦合，后续可替换模型 Provider 或新增工具而不改核心循环。
- 备选：
  - 全部耦合在单模块：短期快，但扩展风险和测试成本高。

### 4) 模型接入采用 req_llm 统一调用
- 选择：Agent 只依赖内部 `LLM client` 协议，协议实现基于 `req_llm`。
- 原因：与底层模型 Provider 解耦，减少后续切换成本。
- 备选：
  - 直接手写 OpenAI HTTP 调用：定制更灵活，但重复轮子、维护负担更高。

### 5) 工具集限制为 `ls` 与 `read`，并实施路径安全策略
- 选择：工具白名单 + 根目录约束 + 路径规范化 + 内容长度限制。
- 原因：MVP 阶段优先降低误操作与越界风险，同时保持能力可验证。
- 备选：
  - 直接开放任意文件系统操作：能力更强但风险不可控。

### 6) 追踪输出使用结构化事件
- 选择：每一步记录 `step`, `thought`, `action`, `input`, `observation`, `result`。
- 原因：便于调试、测试断言与后续可视化。
- 备选：
  - 仅打印自然语言日志：可读性有，但难以自动化校验。

### 7) Session-Oriented 演进采用 ReAct-first 扩展
- 选择：从“单次 `ask_sync`”演进到“会话常驻 + 消息驱动”时，优先扩展 `Jido.AI.ReAct` 的信号、策略和状态机，不重建并行执行内核。
- 原因：最大化复用 `jido_ai` 的 runtime/directive/signal 合同，降低维护成本与行为偏差风险。
- 约束：除非现有 contract 无法覆盖需求，不新增替代性的 `llm_runner/tool_runner`。

### 8) OTP 监督结构以 Jido Instance 为中心
- 选择：执行生命周期由 `Jido.AgentServer` 承担，不额外引入独立 `SessionSupervisor` 作为执行核心。
- 结构：

```text
Prehen.Application
├─ Prehen.Jido                        (Jido instance supervisor)
│  ├─ Prehen.Jido.TaskSupervisor
│  ├─ Prehen.Jido.Registry
│  └─ Prehen.Jido.AgentSupervisor
│     └─ Prehen.Agent.ReActAgent      (one or many agent servers)
└─ Prehen.Agent.EventBridge (optional, signal->cli/ui projection)
```

- 说明：
  - LLM/tool 异步执行继续复用 `Directive.LLMStream` 和 `Directive.ToolExec`。
  - 多会话编排优先在 Agent 状态与信号层扩展，必要时再引入独立 session registry/process。

### 9) 模块边界围绕 ReAct 扩展
- 选择：会话能力通过 strategy/machine/signal 扩展进入现有 ReAct 路径。
- 建议模块：

```text
lib/prehen/agent/
  react_agent.ex              # use Jido.AI.Agent + Prehen actions + public APIs
  runtime.ex                  # CLI/外部入口，负责启动/查找 agent 与请求提交
  event_bridge.ex             # 将 ai.* signal 投影到 CLI/UI 可消费事件流（可选）
  signal/
    session_steer.ex          # Prehen 扩展信号: ai.session.steer
    session_follow_up.ex      # Prehen 扩展信号: ai.session.follow_up
  strategies/
    react_ext.ex              # 在 ReAct strategy 上增加 steer/follow_up 路由与策略逻辑
    react_machine_ext.ex      # 扩展 machine 消息与状态（pending queues / interrupted tools）
  directives/                 # 仅在现有 directives 不足时新增
    emit_session_event.ex
  policies/
    retry_policy.ex           # 可插拔重试策略
    model_router.ex           # 可插拔模型路由
```

### 10) 双层循环映射为状态机相位
- 选择：不在 Prehen 侧编写长 while 循环，采用 ReAct state machine 推进。
- 映射：

```text
outer loop  -> 是否消费 followup_q
inner loop  -> :llm <-> :tools 相位切换
```

- 建议状态字段放在 `agent.state.__strategy__`：
  - `status`: `:idle | :running | :stopping | :done | :error`
  - 输入队列：`prompt_q`, `steer_q`, `followup_q`
  - Turn：`turn_id`, `turn_phase`, `pending_tool_calls`, `skipped_tool_calls`, `current_task_ref`
  - 上下文：`messages`, `partial_message`
  - 策略：`retry`, `model`

### 11) Steering / Follow-Up 注入与中断语义
- 三类消息入口：
  - `prompt`：空闲或普通执行时注入
  - `steering`：工具执行期间高优先级注入
  - `follow-up`：一轮结束后注入下一轮
- 中断规则：
  - 工具链中收到 steering 时，剩余工具标记 skipped
  - observation 统一返回：`"Skipped due to queued user message"`
  - 注入 steering 后继续推进内层循环

### 12) 流式消息与事件系统统一采用 Jido Signal
- 流式占位消息映射：
  - `ai.llm.delta`：更新 `partial_message`
  - `ai.llm.response`：`partial -> final` 并入历史
  - `ai.request.failed`（`{:cancelled, reason}`）：走中断收敛
  - 中断时：partial 有内容则保留，无内容则丢弃并上报 `aborted`
- 事件分层：
  - 命令：`ai.react.query`, `ai.react.cancel`, `ai.session.steer`, `ai.session.follow_up`
  - 生命周期：`ai.request.started/completed/failed/error`
  - 执行：`ai.llm.*`, `ai.tool.*`, `ai.usage`, `ai.react.step`
  - Session 编排：`ai.session.turn.started/completed`, `ai.session.queue.drained`
- Correlation 字段：
  - `session_id`, `request_id`, `run_id`, `turn_id`, `call_id`, `parent_call_id`, `source`, `at_ms`
  - `request_id` 为主相关键；`run_id` 默认等于 `request_id`；`session_id` 由 Session 层注入
- 命名约束：
  - 不引入 `agent_start/agent_end`、`message_start/update/end`、`tool_execution_*` 等旧别名
  - CLI/UI/日志/测试统一直接消费 `ai.request.* / ai.llm.* / ai.tool.* / ai.react.step / ai.session.*`

### 13) Steering / Follow-Up 分层落地策略
- 结论：`jido/jido_ai/jido_action` 的现有信号能力足够先落地基础版，再演进完整版。
- 基础版（近期）：
  - 复用 `ai.react.query` + `ai.react.cancel` + `ai.request.*`
  - Follow-Up：上一请求完成后追加新 query
  - Steering：先 cancel，再注入高优先级 query
- 完整版（后续）：
  - 扩展 ReAct strategy/machine 增加 steering/follow-up 专用路由与 pending 队列
  - 增加工具链逐步中断检查与 skipped tool result 注入
  - 保持 Session 层抽象接口，内部实现可从 `cancel + query` 平滑升级

## Risks / Trade-offs

- [LLM 输出不稳定导致 action 格式错误] → 在解析层加入严格 schema 校验，失败时走 recover 分支并重试。
- [`read` 返回内容过长导致上下文膨胀] → 限制 `max_bytes` 与可选行范围参数，超限时截断并提示。
- [路径穿越风险（`../`）] → 先规范化路径，再校验必须落在允许根目录内。
- [`jido_ai` 与 `req_llm` 消息结构差异] → 通过单一 Adapter 进行标准化映射，避免在业务层分散处理。
- [CLI 体验与未来 API 形态可能差异] → 核心逻辑不依赖 CLI，CLI 仅负责参数解析与调用编排器。
- [ReAct busy 默认 reject，无法天然排队 follow-up] → Session 层先显式排队，后续再评估扩展 `request_policy`。
- [`cancel` 是 advisory，LLM/工具任务可能继续执行一段时间] → 通过 task_ref + timeout + 结果幂等忽略收敛状态。
- [现有 cancel 语义偏向 terminated/error，不等于“跳过剩余工具后继续回合”] → 基础版先采用回合级中断语义，完整版再扩展 machine 语义。
- [事件缺失统一相关键会导致观测与回放困难] → 强制注入 `session_id/request_id/run_id/turn_id/call_id`。

## Migration Plan

1. 保持已交付 MVP 接口稳定（`prehen run`、`ls/read`、现有 ReAct 行为）。
2. 引入 Session API 与三类消息入口（`prompt/steering/follow-up`），内部先映射到 `query/cancel/query`。
3. 将执行驱动升级为“入队 + state machine step”，并接入基础版 follow-up 串行续接。
4. 标准化信号事件与 correlation 字段，统一 CLI/UI/日志的消费契约。
5. 增量扩展 ReAct strategy/machine，实现完整版语义（pending 队列、工具中断检查、skipped tool result）。
6. 最后补齐可插拔策略（retry policy、model router）并做压测与稳定性回归。

回滚策略：
- 若会话化改造不稳定，回退到“单次 ReAct 请求”模式，保留 Session 抽象接口但停用 steering/follow-up。

## Open Questions

- `req_llm` 在项目中采用哪种默认模型与参数（temperature、max_tokens）最适合 ReAct 稳定性？
- CLI trace 默认输出到 stdout 还是文件（如 `tmp/traces/*.jsonl`）？
- 读取二进制文件时应直接拒绝还是返回摘要提示？
- 是否需要在 `jido_ai` 层引入 queue 型 `request_policy`，还是坚持由 Session 层显式排队？
- `steering/follow-up` 最终是否升级为 ReAct 原生信号（如 `ai.react.steer`），还是长期保留 `ai.session.*` 映射层？
- 工具执行中的中断一致性目标是什么（强一致停止 vs 最终一致收敛）？
