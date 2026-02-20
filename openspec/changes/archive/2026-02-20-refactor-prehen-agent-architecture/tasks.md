## 1. 基线冻结与契约确认

- [x] 1.1 冻结当前 CLI 行为基线，补齐 `prompt/steer/follow_up/await_idle` 的回归用例
- [x] 1.2 定稿 typed event envelope 字段与 `trace_json` 新结构文档
- [x] 1.3 明确一次性重构切换边界，移除长期 compat mode 相关实现计划

## 2. 平台监督树与运行时内核重构

- [x] 2.1 在 `Prehen.Application` 中引入目标监督拓扑（AgentSupervisor、SessionManager、SessionSupervisor、MemorySupervisor、ConversationStore、ProjectionSupervisor）
- [x] 2.2 将现有运行时流程拆分为稳定子系统边界，去除 Session 单体编排耦合
- [x] 2.3 固化子系统健康检查与启动失败日志，保证故障可定位

## 3. Multi-Session Workspace 落地

- [x] 3.1 实现 workspace 下多 session 并发创建与状态查询 API
- [x] 3.2 引入 Session 生命周期状态机（创建、运行、停止、回收）
- [x] 3.3 将 `prompt/steering/follow-up` 队列所有权上收至 Session 编排层
- [x] 3.4 实现会话空闲检测与资源清理策略
- [x] 3.5 明确并落地 `SessionManager` 仅 control plane 的职责边界（执行状态由 session 进程持有）

## 4. Multi-Agent Orchestration 落地

- [x] 4.1 实现 Coordinator/Orchestrator/Worker 角色进程与职责边界
- [x] 4.2 定义可插拔路由策略接口，支持规则驱动、模型驱动与混合模式
- [x] 4.3 实现子任务分发、汇总回收与失败隔离降级路径
- [x] 4.4 补齐跨 Agent 关联字段输出（`agent_id`、`parent_call_id` 等）

## 5. Two-Tier Memory 接入（接口优先）

- [x] 5.1 落地 session 级 STM（conversation buffer、working context、token budget）
- [x] 5.2 定义通用 LTM adapter contract，支持本地/远端实现接入点
- [x] 5.3 在 Orchestrator 中接入 memory 读写调用边界（仅接口，不实现具体 LTM 后端）
- [x] 5.4 实现 “STM 主、LTM 补充” 读取顺序与 LTM 失败降级行为
- [x] 5.5 补齐 LTM 接口兼容性 contract tests（mock/stub adapters）

## 6. Conversation/Event Store 与 Trace 升级

- [x] 6.1 实现 canonical conversation/event store 的统一写入接口
- [x] 6.2 实现事件 append-only 存储与按 `session_id` 回放能力
- [x] 6.3 将 CLI `trace_json` 一次性升级到新结构并移除旧字段映射
- [x] 6.4 实现 CLI/日志/指标的投影消费链路

## 7. Tool Packs 改造与 Local FS 迁移

- [x] 7.1 引入 capability pack 注册机制，支持按 workspace 启用/禁用
- [x] 7.2 将 `local-fs-tools` 迁移为可插拔 pack，并保持 `ls/read` 语义一致
- [x] 7.3 补齐 workspace 级 capability allowlist 与权限边界校验
- [x] 7.4 校验 steering 中断下工具 skipped 语义与无副作用保证

## 8. Client Surface Contract 统一

- [x] 8.1 定义统一会话 API（创建、提交消息、状态查询、停止）并用于 CLI 实现
- [x] 8.2 提供统一事件订阅契约，支持 Web/Native 初期直连接入
- [x] 8.3 统一请求关联字段与错误/超时返回结构
- [x] 8.4 在 MVP 范围中明确“认证与鉴权后置”，并记录后续安全机制补齐计划

## 9. 测试、验收与一次性切换

- [x] 9.1 新增跨能力集成测试（orchestration/session/memory/event-store）
- [x] 9.2 完成 `trace_json` 解析用例与内部消费者迁移验证
- [x] 9.3 执行全链路回归与关键场景压测，确认行为兼容
- [x] 9.4 切换默认执行路径到新架构并发布，保留版本级回滚预案
