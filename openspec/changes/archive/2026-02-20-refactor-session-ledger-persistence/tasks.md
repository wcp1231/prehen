## 1. Session Ledger 基础设施

- [x] 1.1 新增 ledger 存储配置与默认目录 `./.prehen/sessions`
- [x] 1.2 实现 `session_id.jsonl` 文件命名、路径解析与目录自动创建
- [x] 1.3 实现最小权限策略（目录 `0700`、文件 `0600`）并补充权限校验测试
- [x] 1.4 实现 JSONL append-only 写入与记录标准化（含 `session_id/seq/kind/at_ms/stored_at_ms`）
- [x] 1.5 实现 ledger 读取与顺序回放基础能力（按 `seq` 排序）
- [x] 1.6 实现 ledger 损坏“硬失败”策略与可诊断错误结构

## 2. Conversation.Store 重构到 Ledger-First

- [x] 2.1 重构 `Conversation.Store.write/2` 与 `write_many/2` 为“先持久化后发布”
- [x] 2.2 保持 `append/2` 与 `append_many/2` 调用语义并统一走持久化路径
- [x] 2.3 重构 `replay/2` 从 ledger 读取并保留 `kind/from_seq` 过滤语义
- [x] 2.4 在回合完成记录写入时实现默认“每回合同步” durability checkpoint（`file.sync`）
- [x] 2.5 更新/补充 store 与 projection 相关测试，覆盖重启后回放场景

## 3. Session 回合摘要与 STM 重建

- [x] 3.1 在 `Session` 回合完成路径写入 `ai.session.turn.summary` 记录
- [x] 3.2 规范 summary 字段（`turn_id/input/answer/status/tool_calls/working_context`）并补充测试
- [x] 3.3 实现 STM projector：从 summary 序列重建 `conversation_buffer`
- [x] 3.4 实现 STM projector：重建 `working_context` 与 `token_budget`
- [x] 3.5 增加恢复后 STM 可继续写入与读取的测试（含 LTM 不可用降级场景）

## 4. 历史 Session 恢复生命周期

- [x] 4.1 扩展 `Session` 启动参数以支持外部传入 `session_id` 与恢复后的 `turn_seq`
- [x] 4.2 在 `SessionManager` 增加恢复入口与控制面元数据编排
- [x] 4.3 确保 session 回收/停止不删除 ledger 文件（仅释放运行时进程资源）
- [x] 4.4 在恢复成功时发出 `ai.session.recovered` 事件并保持 correlation 一致性
- [x] 4.5 增加恢复失败分支测试（ledger 损坏 -> 硬失败）

## 5. Runtime / Surface / Public API 契约扩展

- [x] 5.1 在 Runtime 层增加恢复会话 API（或 create+resume 统一入口）
- [x] 5.2 在 Surface 层暴露统一恢复契约并返回标准错误结构
- [x] 5.3 在 `Prehen` facade 暴露恢复接口并补充类型/文档
- [x] 5.4 补充端到端测试：恢复后 `session_id` 保持不变、请求与事件关联字段一致

## 6. CLI 续聊入口

- [x] 6.1 为 CLI 增加 `--session-id` 续聊参数解析
- [x] 6.2 调整 `prehen run` 流程为“新建或恢复”会话执行语义
- [x] 6.3 补充 CLI 集成测试：指定历史 `session_id` 后可继续对话并输出连续 trace

## 7. 收尾与验证

- [x] 7.1 清理内存事实源旧路径，确保统一切换到 ledger-first（BREAKING）
- [x] 7.2 补充重启恢复集成测试（重启前写入、重启后恢复、继续对话）
- [x] 7.3 补充并发会话隔离测试（各自写入独立 `session_id.jsonl`）
- [x] 7.4 更新架构文档与运行说明（目录、权限、恢复语义、已知限制）
