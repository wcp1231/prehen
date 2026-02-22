## Requirements

### Requirement: Workspace 目录结构
系统 MUST 将 `workspace` 定义为一个物理目录，并使用 `$WORKSPACE_DIR/.prehen/` 作为 Agent 资源根目录，其中 SHALL 包含 `config/`、`sessions/`、`memory/`、`plugins/`、`tools/`、`skills/` 子目录；同时 SHALL 使用 `$WORKSPACE_DIR/.prehen/config/` 作为结构化配置目录，支持 `providers.yaml`、`agents.yaml`、`runtime.yaml`、`secrets.yaml` 文件。

#### Scenario: workspace 配置目录包含结构化配置文件
- **WHEN** 系统初始化或运行时加载 workspace 配置
- **THEN** 系统 SHALL 从 `$WORKSPACE_DIR/.prehen/config/` 解析上述结构化配置文件

#### Scenario: 配置目录不存在 models.yaml
- **WHEN** `$WORKSPACE_DIR/.prehen/config/` 不存在 `models.yaml`
- **THEN** 系统 SHALL 不将其视为缺失错误，并继续按 Provider/Agent 内模型配置运行

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
系统 MUST 支持 `$HOME/.prehen/global/` 作为全局资源基线，并按“workspace 优先、global 回退”解析 `config/plugins/tools/skills` 同名资源；结构化配置 SHALL 支持 `$HOME/.prehen/global/config/` 作为基线并按同名配置文件进行回退。

#### Scenario: workspace 存在同名资源
- **WHEN** `$WORKSPACE_DIR/.prehen/<type>/<name>` 与 `$HOME/.prehen/global/<type>/<name>` 同时存在
- **THEN** 系统 SHALL 优先使用 workspace 资源并覆盖 global 同名项

#### Scenario: workspace 缺失资源
- **WHEN** workspace 目录中不存在某个资源项且 global 中存在同名项
- **THEN** 系统 SHALL 回退使用 `$HOME/.prehen/global/` 下的资源

#### Scenario: workspace 存在同名配置文件
- **WHEN** workspace 与 global 同时存在 `providers.yaml` 或 `agents.yaml`
- **THEN** 系统 SHALL 优先使用 workspace 文件

#### Scenario: workspace 缺失配置文件
- **WHEN** workspace 缺失 `runtime.yaml` 或 `secrets.yaml` 且 global 存在对应文件
- **THEN** 系统 SHALL 回退使用 global 配置文件
