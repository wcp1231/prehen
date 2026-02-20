## Context

当前系统中，`Prehen.Conversation.Store` 与 `Prehen.Memory.STM` 都以进程内状态为主，重启后会丢失会话历史与短期上下文，无法继续历史 session。与此同时，`STM`（短期工作集）与会话历史事实流（对话、toolcall、trace）的职责边界不够明确，导致“谁是事实源、谁可重建”的认知与实现均不稳定。

本次变更的约束与前提：
- 采用文件持久化，不引入数据库；
- 一个 session 对应一个 ledger 文件：`<session_id>.jsonl`；
- 不保留历史兼容路径，允许一次性切换；
- 目标技术栈保持 Elixir/OTP，沿用现有 Runtime/SessionManager/Session/Store 分层。

目标后的数据分层：

```text
session_id.jsonl (Session Ledger, 持久化事实源)
        |
        +--> Conversation.Store (读写/回放/发布 facade)
        |
        +--> STM projector (重放构建内存态 STM)
                |
                +--> Prehen.Memory.STM (内存工作集)

LTM (跨会话长期知识) 独立于 Session Ledger
```

## Goals / Non-Goals

**Goals:**
- 建立 `session_id.jsonl` 作为单一 Session Ledger 事实源，持久化对话历史、toolcall 历史与执行事件。
- 将 `Conversation.Store` 收敛为 ledger-first 的统一接口（append/replay/publish）。
- 系统重启后支持按 `session_id` 重放恢复，并继续历史 session 对话。
- 保持 `STM` 为内存态短期工作集，并可由 ledger 重建。
- 明确 `LTM` 只承载跨会话长期知识（如偏好、常用工具），不存会话事实流。

**Non-Goals:**
- 不引入数据库或分布式存储；
- 不做多节点并发写同一 session 文件的保证（先按单节点模型设计）；
- 不在本次实现中覆盖加密、压缩、归档分层存储；
- 不为旧内存态行为提供长期双轨兼容。

## Decisions

### Decision 1: `session_id.jsonl` 作为 Session Ledger 的 canonical source

**选择：**
- 每条会话记录（event/message/record）作为一行 JSON 追加写入 `<session_id>.jsonl`。
- 保留统一字段：`session_id`、`seq`、`kind`、`at_ms`、`stored_at_ms`，以及 typed envelope 与业务 payload。

**理由：**
- JSONL 与 append-only 事件语义天然匹配，便于回放、审计与故障排查；
- 单文件对应单会话，运维与定位成本低，满足当前约束。

**备选方案与取舍：**
- 备选 A：仅在回合结束时写整份 session 快照。  
  放弃原因：崩溃时丢失窗口大，且 trace/toolcall 时间线不完整。
- 备选 B：数据库事件表。  
  放弃原因：超出本次“文件持久化优先”的范围。

### Decision 2: 写入策略采用“逐记录 append + 回合完成 durability checkpoint”

**选择：**
- `Conversation.Store.write/append` 每次先落盘再发布投影；
- durability checkpoint 默认策略定为“每回合同步”：在 `ai.session.turn.completed` 时执行 `:file.sync/1`，降低 OS 缓冲导致的数据丢失风险。

**理由：**
- 逐记录 append 保证细粒度可追溯；
- 回合边界 checkpoint 在可靠性与性能间折中。

**备选方案与取舍：**
- 备选 A：只在回合结束批量写入。  
  放弃原因：中途崩溃会丢失该回合的 toolcall/delta 历史。
- 备选 B：每条记录都强制 fsync。  
  放弃原因：IO 开销过高，吞吐下降明显。

### Decision 3: `Conversation.Store` 重构为 ledger facade，而非纯内存仓库

**选择：**
- `Conversation.Store` 保留调用接口角色，但内部职责改为：
  1) 计算并分配 `seq`；  
  2) 追加写入 ledger 文件；  
  3) 成功后再 publish 到 projection bus；  
  4) `replay` 从 ledger 读取并按条件过滤（可带轻量内存缓存）。

**理由：**
- 对外语义统一，避免业务层直接感知底层存储；
- “先持久化后发布”避免投影消费到未持久化的幽灵事件。

**备选方案与取舍：**
- 备选：继续以内存 map 为主，定期 dump 到文件。  
  放弃原因：事实源分裂，恢复路径复杂且易不一致。

### Decision 4: `STM` 定位为可重建 projection，恢复依赖 ledger 重放

**选择：**
- `Prehen.Memory.STM` 保持内存态；
- 新增 STM 重建路径：`replay(session_id)` -> `STM projector` -> `STM.ensure/put`；
- 为降低重建复杂度，回合结束时写入明确的 turn summary record（含 `turn_id`、`input`、`answer/status`、`tool_calls` 摘要、`working_context` patch）。

**理由：**
- STM 是推理工作集，不应承担持久化事实职责；
- 明确 summary record 可避免仅靠低层事件反推上下文带来的不确定性。

**备选方案与取舍：**
- 备选：完全从 `ai.tool.*`、`ai.react.*` 原始事件推导 STM。  
  放弃原因：规则复杂、脆弱，随事件模型演进易失真。

**STM 重建流程（恢复时）**
- 输入：`session_id`、该 session 的完整 ledger（`session_id.jsonl`）。
- 步骤 1：`Conversation.Store.replay(session_id)` 读取并按 `seq` 排序。
- 步骤 2：筛选 `ai.session.turn.summary`（回合摘要记录，包含 `turn_id`、`input`、`answer/status`、`tool_calls`、`working_context` patch）。
- 步骤 3：`Memory.ensure_session(session_id, opts)` 初始化空 STM。
- 步骤 4：按 `turn_id` 顺序将每条 summary 回放到 STM：
  - 调用 `Memory.record_turn/3` 恢复 `conversation_buffer` 与 `token_budget`；
  - 若 summary 带 `working_context` patch，再调用 `Memory.put_working_context/3` 合并。
- 输出：可继续对话的 STM 快照与恢复后的 `turn_seq`（取最大 `turn_id`）。

### Decision 5: 引入显式“恢复历史会话”生命周期

**选择：**
- 在 Runtime/Surface/SessionManager 增加恢复入口（如 `resume_session(session_id, opts)`，或 `create_session(..., resume: true)`）；
- `Session` 启动时允许使用外部传入 `session_id`，并从 ledger 恢复 `turn_seq`、历史 trace 与 STM；
- 恢复完成后发出恢复事件（如 `ai.session.recovered`）。

**理由：**
- 将“新建会话”与“恢复会话”语义分离，减少调用歧义；
- 保证继续对话时 correlation 字段与历史一致。

**备选方案与取舍：**
- 备选：恢复时创建新 session 并复制历史。  
  放弃原因：破坏原 `session_id` 语义，客户端追踪复杂。

### Decision 6: LTM 严格聚焦跨会话长期知识

**选择：**
- LTM adapter contract 只用于长期知识读写，不承担 session 历史保存；
- session 恢复流程不依赖 LTM，可在恢复后按策略补充长期知识。

**理由：**
- 防止“会话事实流”和“长期语义知识”混层；
- 保持 two-tier memory 语义清晰：STM（当前会话）+ LTM（跨会话）。

## Risks / Trade-offs

- [Risk] JSONL 尾行写入中断导致半行损坏 -> Mitigation：当前策略为“硬失败”（恢复直接失败并报错），优先暴露数据问题，后续可评估降级容错。
- [Risk] 单文件随会话变长导致重放耗时上升 -> Mitigation：引入周期性 checkpoint/summary record，并支持“从 checkpoint 之后回放”。
- [Risk] 文件 IO 增加影响吞吐 -> Mitigation：采用 append-only 顺序写，checkpoint 配置化，避免每条记录强制 fsync。
- [Risk] Store 发布与持久化顺序不当导致不一致 -> Mitigation：严格执行“persist 成功后 publish”。
- [Risk] 恢复语义过于隐式导致客户端误用 -> Mitigation：在 client contract 中显式区分 create 与 resume，并统一错误结构。
- [Risk] 本次不做多节点并发写控制 -> Mitigation：在文档与配置中声明单节点约束，后续如需扩展再引入分布式锁或中心化存储。

## Migration Plan

1. 定义 `SessionLedger` 文件布局与记录 schema，落地 `session_id.jsonl` 读写组件。  
2. 重构 `Conversation.Store` 到 ledger-first 写入/回放路径，并保持 projection 发布能力。  
3. 在 `Session` 回合完成时写入 turn summary record；新增 recovery projector 以重建 STM。  
4. 扩展 `SessionManager/Runtime/Surface` 恢复入口，支持按 `session_id` 重建并继续会话。  
5. 更新 CLI/runtime contract（新建/恢复语义），补齐集成测试（重启前后继续会话、toolcall 历史回放）。  
6. 切换为新模型（BREAKING）：移除对“内存态即事实源”的依赖路径。  

**Rollback strategy:**
- 版本级回滚：回滚到上一版本二进制；新写入的 `.jsonl` 文件保留但旧版本可忽略；
- 配置级紧急降级（可选）：保留临时开关以禁用恢复入口，仅允许新建会话（不建议长期保留）。

## Open Questions

- 恢复 API 最终形态采用独立 `resume_session/2`，还是复用 `create_session/1 + resume` 参数？
- `session_id.jsonl` 目录默认位置暂定为 `./.prehen/sessions`，文件权限策略是否固定为 `0600`（owner read/write）？
