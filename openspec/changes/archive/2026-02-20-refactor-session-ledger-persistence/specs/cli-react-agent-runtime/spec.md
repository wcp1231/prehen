## ADDED Requirements

### Requirement: CLI 恢复会话入口
系统 MUST 为 CLI 提供恢复历史 session 的显式入口，并支持在恢复后继续同一会话执行。

#### Scenario: CLI 指定历史 session 继续对话
- **WHEN** 用户执行 `prehen run --workspace ws-1 --session-id <session_id> "继续这个任务"`
- **THEN** 系统 SHALL 恢复对应会话并在同一 `session_id` 下继续 ReAct 回合

## MODIFIED Requirements

### Requirement: CLI 任务执行入口
系统 MUST 提供 CLI 命令入口以接收自然语言任务并触发平台化运行时执行流程，并支持在指定 workspace 下创建新 session 或恢复历史 session。

#### Scenario: 用户提交任务并绑定 workspace
- **WHEN** 用户执行 `prehen run --workspace ws-1 "列出 lib 并读取 prehen.ex"`
- **THEN** 系统 SHALL 在 `ws-1` 下创建新会话并启动一次 ReAct 回合

#### Scenario: 用户恢复历史会话并继续任务
- **WHEN** 用户执行 `prehen run --workspace ws-1 --session-id s-123 "继续上次分析"`
- **THEN** 系统 SHALL 恢复 `s-123` 并继续执行新的回合

### Requirement: Session-Oriented ReAct 执行模型
系统 MUST 以会话化方式运行 ReAct，并将 `prompt / steering / follow-up` 的排队与中断语义收敛到 Session 编排层；在恢复会话场景下 SHALL 保持回合序号与会话上下文连续。

#### Scenario: 正常多步执行并完成
- **WHEN** Agent 在若干轮中产出合法 action 并获得 observation
- **THEN** 系统 SHALL 在当前会话内持续迭代 `think -> action -> observation`，并在满足完成条件时输出 final answer

#### Scenario: 恢复后继续执行
- **WHEN** 系统已恢复某历史 session 并收到新 prompt
- **THEN** 系统 SHALL 基于恢复后的上下文继续后续回合，而非创建独立执行上下文

### Requirement: 统一 Signal 事件契约
系统 MUST 输出 typed event envelope，并在 CLI `trace_json` 中使用升级后的统一事件结构，不保留旧字段兼容输出；恢复会话 SHALL 发出可追踪恢复事件。

#### Scenario: 执行期间输出标准事件
- **WHEN** Agent 处理请求、模型流、工具调用与回合推进
- **THEN** 系统 SHALL 使用 `ai.request.* / ai.llm.* / ai.tool.* / ai.react.step / ai.session.*` 事件命名并附带标准 envelope

#### Scenario: 会话恢复事件
- **WHEN** 系统成功恢复某历史 `session_id`
- **THEN** 系统 SHALL 输出恢复事件并携带标准 correlation 字段
