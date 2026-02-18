## Why

当前 MVP 已验证 `jido + jido_ai + req_llm` 的单次任务闭环能力，但还缺少会话化运行能力：
- 无 `prompt / steering / follow-up` 三类消息入口
- 无面向中断与续接的双层循环语义
- 事件与相关键（correlation）契约尚未统一

需要在保持 CLI MVP 可用的前提下，演进到 Session-Oriented Agent Loop，为后续交互式 Agent 能力打基础。

## What Changes

- 将运行时从“单次 `ask_sync` 调用”演进为“会话常驻 + 消息驱动”模型。
- 在 `Jido.AI.ReAct` 上做增量扩展，新增 `steering/follow-up` 路由与队列语义，避免重建并行执行内核。
- 统一事件模型，采用 `ai.request.* / ai.llm.* / ai.tool.* / ai.react.step / ai.session.*` 作为标准信号契约。
- 标准化 correlation 字段（`session_id/request_id/run_id/turn_id/call_id`），保证可观测与回放一致性。
- 保持 CLI 入口与本地工具（`ls`/`read`）稳定，优先完成基础版（`cancel + query` 映射）再演进完整版（工具链精细中断）。

## Capabilities

### New Capabilities
- 无

### Modified Capabilities
- `cli-react-agent-runtime`: 从单次执行升级为 Session-Oriented ReAct Loop，支持 `prompt/steering/follow-up` 与标准信号事件模型。
- `local-fs-tools`: 明确会话中断场景下的“跳过执行（skipped）”语义，保障工具层只读与可诊断错误输出。

## Impact

- Affected code:
  - `lib/prehen/agent/**`（Session 状态、ReAct 扩展、信号桥接）
  - `lib/prehen/actions/**`（工具返回结构与 skipped 兼容语义）
  - `lib/prehen/cli.ex` / `lib/mix/tasks/prehen.run.ex`（CLI 调用链保持兼容并接入会话入口）
  - `test/**`（新增会话队列、中断、信号契约与回归测试）
- Dependencies:
  - `jido`
  - `jido_ai`
  - `req_llm`
- Runtime/API:
  - 保持 `prehen run "<task>"` 入口兼容
  - 新增会话级消息注入能力（内部 API）与标准 signal 输出契约
  - 继续依赖模型配置（如 API key、model name）
