## Requirements

### Requirement: CLI 恢复会话入口
系统 MUST 为 CLI 提供恢复历史 session 的显式入口，并支持在绑定 workspace 物理目录中恢复后继续同一会话执行。

#### Scenario: CLI 指定历史 session 继续对话
- **WHEN** 用户执行 `prehen run --workspace /projects/ws-1 --session-id <session_id> "继续这个任务"`
- **THEN** 系统 SHALL 在 `/projects/ws-1` 绑定目录中恢复对应会话，并在同一 `session_id` 下继续 ReAct 回合

#### Scenario: CLI 未显式提供 workspace 时恢复历史会话
- **WHEN** 用户执行 `prehen run --session-id <session_id> "继续这个任务"`
- **THEN** 系统 SHALL 在默认目录 `$HOME/.prehen/workspace` 下执行恢复流程

### Requirement: CLI 任务执行入口
系统 MUST 提供 CLI 命令入口以接收自然语言任务并触发平台化运行时执行流程，并支持在指定 workspace 物理目录下创建新 session 或恢复历史 session，同时支持按 Agent 模板执行。

#### Scenario: 用户通过 Agent 模板执行任务
- **WHEN** 用户执行 `prehen run --agent coder "列出 lib 并读取 prehen.ex"`
- **THEN** 系统 SHALL 加载 `coder` 模板配置并基于该模板启动会话执行

#### Scenario: 用户通过 Agent 模板恢复历史会话
- **WHEN** 用户执行 `prehen run --agent coder --session-id s-123 "继续上次分析"`
- **THEN** 系统 SHALL 在恢复 `s-123` 后按 `coder` 模板配置继续执行后续回合

#### Scenario: 用户提交任务并绑定 workspace 路径
- **WHEN** 用户执行 `prehen run --workspace /projects/ws-1 "列出 lib 并读取 prehen.ex"`
- **THEN** 系统 SHALL 在 `/projects/ws-1` 下创建新会话并启动一次 ReAct 回合

#### Scenario: 用户恢复历史会话并继续任务
- **WHEN** 用户执行 `prehen run --workspace /projects/ws-1 --session-id s-123 "继续上次分析"`
- **THEN** 系统 SHALL 在 `/projects/ws-1` 下恢复 `s-123` 并继续执行新的回合

#### Scenario: 用户未提供 workspace 参数
- **WHEN** 用户执行 `prehen run "继续分析"` 且未提供 `--workspace`
- **THEN** 系统 SHALL 使用默认 workspace 路径 `$HOME/.prehen/workspace`

### Requirement: CLI 参数兼容与移除策略
系统 MUST 将已移除参数视为无效输入并返回参数错误。

#### Scenario: 用户提供已移除参数 --root-dir
- **WHEN** 用户执行 `prehen run "任务" --root-dir ./tmp`
- **THEN** 系统 SHALL 将该输入视为无效参数并返回参数错误

#### Scenario: 用户提供已移除参数 --model
- **WHEN** 用户执行 `prehen run --model openai:gpt-5-mini "任务"`
- **THEN** 系统 SHALL 将该输入视为无效参数并返回参数错误

### Requirement: Session-Oriented ReAct 执行模型
系统 MUST 以会话化方式运行 ReAct，并将 `prompt / steering / follow-up` 的排队与中断语义收敛到 Session 编排层；在恢复会话场景下 SHALL 保持回合序号与会话上下文连续。

#### Scenario: 正常多步执行并完成
- **WHEN** Agent 在若干轮中产出合法 action 并获得 observation
- **THEN** 系统 SHALL 在当前会话内持续迭代 `think -> action -> observation`，并在满足完成条件时输出 final answer

#### Scenario: 恢复后继续执行
- **WHEN** 系统已恢复某历史 session 并收到新 prompt
- **THEN** 系统 SHALL 基于恢复后的上下文继续后续回合，而非创建独立执行上下文

#### Scenario: 达到最大步数后终止
- **WHEN** 当前执行步数达到 `max_steps` 且尚未满足完成条件
- **THEN** 系统 SHALL 终止执行并返回部分结果与终止原因

### Requirement: Steering 中断语义
系统 MUST 支持在执行过程中注入 steering 消息，并由 Session 队列层统一决定剩余工具调用的跳过与续接行为。

#### Scenario: 工具链执行中收到 steering
- **WHEN** 会话处于工具执行阶段且收到 steering 消息
- **THEN** 系统 SHALL 跳过尚未执行的工具调用，并向模型注入 observation：`Skipped due to queued user message`

### Requirement: Follow-Up 续接语义
系统 MUST 支持在一个回合结束后自动消费 follow-up 消息并开始下一回合，且续接过程保持同一 session 的状态连续性。

#### Scenario: 当前回合结束且存在 follow-up
- **WHEN** 当前请求完成且 `follow-up` 队列非空
- **THEN** 系统 SHALL 在同一会话中继续下一轮 ReAct 回合，而不是创建全新独立执行上下文

### Requirement: 流式消息占位管理
系统 MUST 对流式 LLM 响应维护 `partial_message`，并在完成或中断时进行一致性收敛，保证 canonical conversation store 可回放。

#### Scenario: 正常流式完成
- **WHEN** 系统接收 `ai.llm.delta` 与最终 `ai.llm.response`
- **THEN** 系统 SHALL 先增量更新 partial，再在响应结束时落盘为 final message

#### Scenario: 流式中断
- **WHEN** 请求因取消或失败而中断
- **THEN** 系统 SHALL 在 partial 有内容时保留历史，否则丢弃并标记为 aborted

### Requirement: 统一 Signal 事件契约
系统 MUST 输出 typed event envelope，并在 CLI `trace_json` 中使用升级后的统一事件结构，不保留旧字段兼容输出；恢复会话 SHALL 发出可追踪恢复事件。

#### Scenario: 执行期间输出标准事件
- **WHEN** Agent 处理请求、模型流、工具调用与回合推进
- **THEN** 系统 SHALL 使用 `ai.request.* / ai.llm.* / ai.tool.* / ai.react.step / ai.session.*` 事件命名并附带标准 envelope

#### Scenario: 会话恢复事件
- **WHEN** 系统成功恢复某历史 `session_id`
- **THEN** 系统 SHALL 输出恢复事件并携带标准 correlation 字段

#### Scenario: 事件具备 correlation 字段
- **WHEN** 系统发出关键生命周期或执行事件
- **THEN** 事件 payload SHALL 包含可用的 `session_id`、`request_id`、`run_id`、`turn_id`、`call_id` 等关联字段

### Requirement: 模型调用抽象
系统 MUST 通过统一的 LLM 适配层与 `req_llm` 交互，避免运行时直接耦合具体 Provider，并支持在多 Agent 编排中复用同一调用契约。

#### Scenario: 使用 req_llm 完成一次推理请求
- **WHEN** Agent 需要进行下一步推理
- **THEN** 系统 SHALL 通过 LLM 适配层调用 `req_llm` 并获得可解析响应
