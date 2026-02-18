## Requirements

### Requirement: CLI 任务执行入口
系统 MUST 提供 CLI 命令入口以接收自然语言任务并触发 Agent 执行流程。

#### Scenario: 用户提交任务并启动执行
- **WHEN** 用户执行 `prehen run "列出 lib 并读取 prehen.ex"`
- **THEN** 系统 SHALL 启动一次新的 Agent 会话并进入 ReAct 循环

### Requirement: Session-Oriented ReAct 执行模型
系统 MUST 以会话化方式运行 ReAct，并支持 `prompt / steering / follow-up` 三类消息输入。

#### Scenario: 正常多步执行并完成
- **WHEN** Agent 在若干轮中产出合法 action 并获得 observation
- **THEN** 系统 SHALL 在当前会话内持续迭代 `think -> action -> observation`，并在满足完成条件时输出 final answer

#### Scenario: 达到最大步数后终止
- **WHEN** 当前执行步数达到 `max_steps` 且尚未满足完成条件
- **THEN** 系统 SHALL 终止执行并返回部分结果与终止原因

### Requirement: Steering 中断语义
系统 MUST 支持在执行过程中注入 steering 消息，并对剩余工具调用执行可诊断的跳过策略。

#### Scenario: 工具链执行中收到 steering
- **WHEN** 会话处于工具执行阶段且收到 steering 消息
- **THEN** 系统 SHALL 跳过尚未执行的工具调用，并向模型注入 observation：`Skipped due to queued user message`

### Requirement: Follow-Up 续接语义
系统 MUST 支持在一个回合结束后自动消费 follow-up 消息并开始下一回合。

#### Scenario: 当前回合结束且存在 follow-up
- **WHEN** 当前请求完成且 `follow-up` 队列非空
- **THEN** 系统 SHALL 在同一会话中继续下一轮 ReAct 回合，而不是创建全新独立执行上下文

### Requirement: 流式消息占位管理
系统 MUST 对流式 LLM 响应维护 `partial_message`，并在完成或中断时进行一致性收敛。

#### Scenario: 正常流式完成
- **WHEN** 系统接收 `ai.llm.delta` 与最终 `ai.llm.response`
- **THEN** 系统 SHALL 先增量更新 partial，再在响应结束时落盘为 final message

#### Scenario: 流式中断
- **WHEN** 请求因取消或失败而中断
- **THEN** 系统 SHALL 在 partial 有内容时保留历史，否则丢弃并标记为 aborted

### Requirement: 统一 Signal 事件契约
系统 MUST 以 Jido/ReAct 信号作为唯一标准事件类型，并输出统一相关键字段。

#### Scenario: 执行期间输出标准事件
- **WHEN** Agent 处理请求、模型流、工具调用与回合推进
- **THEN** 系统 SHALL 使用 `ai.request.* / ai.llm.* / ai.tool.* / ai.react.step / ai.session.*` 事件命名

#### Scenario: 事件具备 correlation 字段
- **WHEN** 系统发出关键生命周期或执行事件
- **THEN** 事件 payload SHALL 包含可用的 `session_id`、`request_id`、`run_id`、`turn_id`、`call_id` 等关联字段

### Requirement: 模型调用抽象
系统 MUST 通过统一的 LLM 适配层与 `req_llm` 交互，避免运行时直接耦合具体 Provider。

#### Scenario: 使用 req_llm 完成一次推理请求
- **WHEN** Agent 需要进行下一步推理
- **THEN** 系统 SHALL 通过 LLM 适配层调用 `req_llm` 并获得可解析响应
