## Context

当前系统对 workspace 相关能力存在三套并行语义：
- `workspace_id`：控制面逻辑隔离键；
- `root_dir`：tools 访问根目录；
- `session_ledger_dir`：会话持久化目录。

这三者分别在 `SessionManager`、`PathGuard`、`SessionLedger` 中独立生效，导致用户感知与系统行为不一致。用户提出的新模型是“单一物理 workspace 目录作为事实边界”，并明确：
- `--workspace` 传递物理路径；
- 去掉逻辑 `workspace_id`；
- 去掉 `root_dir`，tools 根目录统一为 workspace 根目录；
- 允许 tools 访问 `$WORKSPACE_DIR/.prehen`；
- 一个 Prehen 进程只管理一个 workspace。

目标目录结构如下：

```text
$WORKSPACE_DIR/
├── .prehen/
│   ├── config/
│   ├── sessions/
│   ├── memory/
│   ├── plugins/
│   ├── tools/
│   └── skills/
└── ... (用户希望 Agent 管理的数据)
```

同时引入全局目录：

```text
$HOME/.prehen/global/
├── config/
├── plugins/
├── tools/
└── skills/
```

并采用 workspace 优先、global 回退的资源解析策略。

## Goals / Non-Goals

**Goals:**
- 建立统一的 workspace 物理目录模型，消除 `workspace_id/root_dir/ledger_dir` 语义分裂。
- 将 Agent 元数据与用户数据在同一 workspace 下分层：`.prehen` 为 Agent 专用区，其余目录为用户数据区。
- 将 session ledger、memory 路径收敛到 `$WORKSPACE_DIR/.prehen/*`。
- 将运行时约束收敛为“单进程单 workspace”，并提供 workspace 不匹配的显式错误。
- 将 CLI 与 runtime contract 对齐为路径化 workspace 输入。
- 定义全局资源与 workspace 资源覆盖规则，支持 Agent 在 workspace 内自主管理元数据。

**Non-Goals:**
- 不在本次引入多进程编排器或跨 workspace 调度器。
- 不在本次确定 `config/` 的文件格式与拆分策略（后续提案处理）。
- 不在本次实现插件/skills 的完整动态加载协议（后续提案处理，本次仅定义目录与解析优先级）。
- 不实现旧 ledger 数据迁移（已确认无历史数据需要迁移）。
- 不在本次加入 `.prehen` 特殊保护策略（tools 允许访问 `.prehen` 是既定决策）。

## Decisions

### Decision 1: 以 `workspace_dir` 作为单一物理边界

**选择：**
- 引入 `workspace_dir` 配置，默认 `$HOME/.prehen/workspace`。
- 所有与当前会话执行、工具访问、持久化落盘相关的路径都从 `workspace_dir` 派生。

**理由：**
- 统一路径来源可以显著降低行为歧义与配置冲突；
- 与用户心智一致：一个 workspace 是一个可见目录树。

**备选方案与取舍：**
- 备选 A：保留 `workspace_id` + `root_dir` + `ledger_dir` 三路并存。  
  放弃原因：继续保留跨模块路径歧义，长期维护成本高。
- 备选 B：保留 `workspace_id` 作为逻辑主键并映射到目录。  
  放弃原因：用户已明确不需要逻辑 ID 层。

### Decision 2: `.prehen` 子目录作为 Agent 专用资源区

**选择：**
- Agent 资源固定在 `$WORKSPACE_DIR/.prehen/` 下，包含：
  - `config/`
  - `sessions/`
  - `memory/`
  - `plugins/`
  - `tools/`
  - `skills/`
- `$WORKSPACE_DIR` 的非 `.prehen` 内容视为用户数据区。

**理由：**
- 在同一 workspace 内清晰区分“Agent 自管元数据”和“用户业务数据”；
- 便于备份、审计、清理与权限管理。

**备选方案与取舍：**
- 备选：将 Agent 资源与用户数据完全混放。  
  放弃原因：边界不清，误删风险与排障成本更高。

### Decision 3: 全局目录采用 fallback 覆盖模型

**选择：**
- 引入 `$HOME/.prehen/global/` 作为全局资源基线（`config/plugins/tools/skills`）。
- 解析顺序为：
  1) `$WORKSPACE_DIR/.prehen/<type>/...`
  2) `$HOME/.prehen/global/<type>/...`
- 同名资源由 workspace 覆盖 global。

**理由：**
- 支持“全局默认 + workspace 定制”的常见工作流；
- 满足不同项目对 tools/skills 的独立配置需求。

**备选方案与取舍：**
- 备选 A：只支持 workspace 目录，不支持 global。  
  放弃原因：无法复用全局公共资源，重复配置过多。
- 备选 B：对同名资源做字段级 merge。  
  放弃原因：行为不可预测，排查复杂；本次采用“整项覆盖”更稳定。

### Decision 4: CLI `--workspace` 语义改为物理路径，移除 `root_dir`

**选择：**
- `--workspace` 接收路径（绝对或相对），解析后作为 `workspace_dir`。
- 去掉 `--root-dir` 及其环境变量，tools 根目录固定为 `workspace_dir`。

**理由：**
- 统一入口参数语义，避免“workspace 与 root_dir 双根目录”的冲突；
- 简化用户输入，降低误配置概率。

**备选方案与取舍：**
- 备选：保留 `--root-dir` 作为 tools 覆盖项。  
  放弃原因：重新引入双边界模型，违背本次收敛目标。

### Decision 5: 去除 `workspace_id`，改为单进程单 workspace 绑定

**选择：**
- runtime/session manager 在进程启动时即绑定一个 `workspace_dir`（来自 CLI `--workspace` 或默认值）。
- 常规后续请求不需要再次传入 `workspace_dir`，直接使用进程已绑定目录。
- 仅当调用方显式传入覆盖型 `workspace_dir` 且与绑定目录不一致时，返回 `workspace_mismatch`（作为防御性保护分支）。
- session metadata、client contract、status 输出移除 `workspace_id` 字段。

**理由：**
- 与用户给出的运维模型一致：多 workspace 通过多进程实现；
- 降低控制面的跨 workspace 状态管理复杂度。
- 避免“每次请求都要带 workspace 参数”的重复负担。

**备选方案与取舍：**
- 备选：单进程继续管理多个 workspace。  
  放弃原因：与本次明确约束冲突，且会放大控制面复杂度。

### Decision 6: ledger 与 memory 路径统一下沉到 `.prehen`

**选择：**
- ledger：`$WORKSPACE_DIR/.prehen/sessions/<session_id>.jsonl`
- memory 文件（若存在文件化落盘）：`$WORKSPACE_DIR/.prehen/memory/`
- 目录权限延续当前策略（目录 `0700`、文件 `0600`）。

**理由：**
- 会话事实流和内存状态都属于 Agent 内部资产，应归入 `.prehen`；
- 保持当前安全基线与恢复语义一致。

**备选方案与取舍：**
- 备选：ledger 继续独立配置目录。  
  放弃原因：再次产生路径分裂与环境漂移。

### Decision 7: tools 允许访问 `.prehen`

**选择：**
- `PathGuard` 仅检查“是否在 workspace 根目录内”，不阻止访问 `.prehen` 子目录。

**理由：**
- 用户明确希望 Agent 可通过工具自主管理元数据；
- 支持自举型流程（Agent 读取/维护自己的配置、skills、工具资源）。

**备选方案与取舍：**
- 备选：默认禁止 tools 访问 `.prehen`。  
  放弃原因：与用户目标冲突，限制 Agent 自管理能力。

### Decision 8: 配置解析收敛为“CLI > workspace config > global config > defaults”

**选择：**
- 统一配置优先级：
  1) CLI/调用参数
  2) `$WORKSPACE_DIR/.prehen/config/*`
  3) `$HOME/.prehen/global/config/*`
  4) 内置 defaults
- 环境变量仅用于默认值兜底，不再提供独立 `root_dir`/`workspace_id` 语义。

**理由：**
- 优先级清晰且可解释；
- 兼容当前配置系统的“参数优先”实践。

**备选方案与取舍：**
- 备选：只允许 CLI 与 defaults，不读取文件配置。  
  放弃原因：无法发挥 workspace/global 配置分层价值。

## Risks / Trade-offs

- [Risk] 允许 tools 访问 `.prehen` 可能导致元数据被误改。  
  Mitigation：保留 append-only ledger 校验、关键写入点统一经 Store/Ledger 接口；在 specs 中明确错误语义与最小保护约束。

- [Risk] `--workspace` 语义变更会破坏现有 CLI 使用习惯。  
  Mitigation：在 CLI 帮助、README、错误提示中明确 BREAKING 变更，并提供路径示例。

- [Risk] 去除 `workspace_id` 后，旧测试与调用方接口大面积改动。  
  Mitigation：按 contract 层到模块层分阶段替换，优先更新 `Surface/Runtime` 再落到 `SessionManager` 与测试。

- [Risk] 单进程单 workspace 降低了进程内多租户能力。  
  Mitigation：明确这是有意简化；通过多进程部署满足多 workspace 需求。

- [Risk] workspace/global 覆盖规则若实现不一致，可能造成资源解析漂移。  
  Mitigation：引入统一路径解析模块（如 `Prehen.Workspace.Paths` / `Prehen.Workspace.Resources`），禁止各模块自行拼路径。

## Migration Plan

1. 新增 workspace 路径抽象层，定义：
   - `workspace_dir`
   - `.prehen` 子目录派生方法
   - global fallback 派生方法
2. 调整配置加载：
   - 增加 `workspace_dir`；
   - 移除 `root_dir`、`workspace_id`；
   - 加入 workspace/global 配置优先级。
3. 调整 CLI contract：
   - `--workspace` 改为路径；
   - 删除 `--root-dir`。
4. 调整 runtime/control-plane contract：
   - 会话 API 去除 `workspace_id`；
   - `SessionManager` 增加单 workspace 绑定与 mismatch 错误。
5. 调整存储路径：
   - `SessionLedger` 与 recovery 路径切换到 `$WORKSPACE_DIR/.prehen/sessions`；
   - memory 相关落盘路径统一到 `.prehen/memory`（若有落盘逻辑）。
6. 调整 tools 根边界：
   - `PathGuard` 根目录改为 `workspace_dir`；
   - 保持 `.prehen` 可访问。
7. 更新文档与测试：
   - README / architecture 文档；
   - CLI、runtime、session manager、ledger、local-fs tools 测试全量更新。

Rollback strategy:
- 版本级回滚到旧版本二进制；
- 由于本次无旧 ledger 迁移需求，不涉及数据回迁；
- 回滚时保留新目录，不自动删除 `.prehen` 资产。

## Open Questions

- `workspace_mismatch` 的错误载荷是否需要标准化为统一 envelope（例如包含 `expected_workspace` 与 `provided_workspace`）？
