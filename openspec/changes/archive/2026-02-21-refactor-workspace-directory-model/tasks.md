## 1. Workspace 路径与目录模型收敛

- [x] 1.1 新增统一的 workspace 路径解析模块（例如 `Prehen.Workspace.Paths`），集中提供 `workspace_dir`、`.prehen` 子目录与 global fallback 路径派生能力
- [x] 1.2 在路径模块中实现默认 workspace 路径 `$HOME/.prehen/workspace` 与 global 路径 `$HOME/.prehen/global` 的标准解析逻辑
- [x] 1.3 在启动/首次使用时补齐 `$WORKSPACE_DIR/.prehen/{config,sessions,memory,plugins,tools,skills}` 目录创建与最小权限策略
- [x] 1.4 将 `SessionLedger` 路径来源切换为 `$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl`，移除对独立 `session_ledger_dir` 的主路径依赖

## 2. 配置层与 CLI 参数改造

- [x] 2.1 更新 `Prehen.Config`：新增 `workspace_dir`，移除 `root_dir` 与 `workspace_id` 语义，固化“CLI > workspace config > global config > defaults”优先级框架
- [x] 2.2 更新 CLI 参数解析：保留 `--workspace` 作为物理路径参数，移除 `--root-dir` 及相关帮助文本
- [x] 2.3 对 `--root-dir` 输入增加明确参数错误提示与失败路径测试用例
- [x] 2.4 更新面向用户的配置文档与示例命令，统一使用 workspace 路径语义

## 3. Runtime/Surface/SessionManager contract 收敛

- [x] 3.1 在 Runtime/Surface 层移除 `workspace_id` 输入输出字段，改为隐式使用进程绑定的 `workspace_dir`
- [x] 3.2 在 SessionManager 中移除 `workspace_id` 控制面元数据与按 `workspace_id` 过滤逻辑，保留单 workspace 内多 session 管理
- [x] 3.3 实现“单进程单 workspace”绑定机制：进程启动即确定绑定 workspace，常规请求无需重复传入
- [x] 3.4 实现防御性 `workspace_mismatch` 分支：仅在显式覆盖 workspace 且与绑定值不一致时返回错误
- [x] 3.5 更新 `session_status/list_sessions/create_session/resume_session` 等 contract 的字段与返回结构，去除 `workspace_id`

## 4. Store/Recovery/Tools 行为对齐

- [x] 4.1 更新 `Conversation.Store` 与 `SessionLedger` 的读写/回放流程，确保全部基于绑定 workspace 的 `.prehen/sessions` 路径
- [x] 4.2 更新 session 恢复流程：仅在当前绑定 workspace 中查找 ledger，找不到时返回恢复失败错误
- [x] 4.3 更新 `PathGuard` 与 tool_context：工具根目录统一为 `workspace_dir`
- [x] 4.4 明确并实现 tools 可访问 `$WORKSPACE_DIR/.prehen` 的路径判定行为（不额外屏蔽该子目录）

## 5. 测试、验证与文档收尾

- [x] 5.1 重构 CLI 测试：覆盖 `--workspace` 路径语义、默认 workspace 行为与 `--root-dir` 移除后的错误分支
- [x] 5.2 重构 Runtime/Surface/SessionManager 测试：覆盖去除 `workspace_id` 后的 contract 与单进程单 workspace 绑定行为
- [x] 5.3 补充 `workspace_mismatch` 场景测试：显式覆盖不一致时拒绝请求且不影响已有会话
- [x] 5.4 重构 ledger/recovery 测试：验证写入与恢复路径均位于 `$WORKSPACE_DIR/.prehen/sessions`
- [x] 5.5 重构 local-fs tools 测试：验证 workspace 根边界与 `.prehen` 可访问行为
- [x] 5.6 更新 `README.md` 与 `docs/architecture/current-system.md`，同步新目录结构、参数语义与运行时约束
