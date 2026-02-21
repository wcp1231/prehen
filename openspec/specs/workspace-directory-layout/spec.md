## Requirements

### Requirement: Workspace 目录结构
系统 MUST 将 `workspace` 定义为一个物理目录，并使用 `$WORKSPACE_DIR/.prehen/` 作为 Agent 资源根目录，其中 SHALL 包含 `config/`、`sessions/`、`memory/`、`plugins/`、`tools/`、`skills/` 子目录。

#### Scenario: 使用默认 workspace 目录
- **WHEN** Prehen 进程启动且调用方未显式提供 `workspace` 路径
- **THEN** 系统 SHALL 使用 `$HOME/.prehen/workspace` 作为 `workspace` 根目录，并按规范组织 `.prehen` 子目录

#### Scenario: 使用自定义 workspace 目录
- **WHEN** 调用方通过 `--workspace <path>` 提供自定义目录
- **THEN** 系统 SHALL 在该目录下按相同结构运行，且 SHALL NOT 额外创建 `workspace_id` 层级目录

### Requirement: Agent 元数据与用户数据分层
系统 MUST 将 Agent 资源与用户数据在同一 workspace 内分层管理：`.prehen` 目录用于 Agent 元数据与资源，`$WORKSPACE_DIR` 其余目录用于用户希望 Agent 管理的数据。

#### Scenario: Agent 访问资源目录
- **WHEN** 系统需要读取会话历史、memory 资产或本地插件/工具/skills 资源
- **THEN** 系统 SHALL 仅从 `$WORKSPACE_DIR/.prehen/` 对应子目录解析相关资源

#### Scenario: Agent 管理用户数据
- **WHEN** Agent 通过工具处理业务文件
- **THEN** 系统 SHALL 允许其访问 `$WORKSPACE_DIR` 中非 `.prehen` 的用户数据区

### Requirement: Global 资源回退与 workspace 覆盖
系统 MUST 支持 `$HOME/.prehen/global/` 作为全局资源基线，并按“workspace 优先、global 回退”解析 `config/plugins/tools/skills` 同名资源。

#### Scenario: workspace 存在同名资源
- **WHEN** `$WORKSPACE_DIR/.prehen/<type>/<name>` 与 `$HOME/.prehen/global/<type>/<name>` 同时存在
- **THEN** 系统 SHALL 优先使用 workspace 资源并覆盖 global 同名项

#### Scenario: workspace 缺失资源
- **WHEN** workspace 目录中不存在某个资源项且 global 中存在同名项
- **THEN** 系统 SHALL 回退使用 `$HOME/.prehen/global/` 下的资源
