## MODIFIED Requirements

### Requirement: Workspace 目录结构
系统 MUST 将 `workspace` 定义为一个物理目录，并使用 `$WORKSPACE_DIR/.prehen/config/` 作为结构化配置目录，支持 `providers.yaml`、`agents.yaml`、`runtime.yaml`、`secrets.yaml` 文件。

#### Scenario: workspace 配置目录包含结构化配置文件
- **WHEN** 系统初始化或运行时加载 workspace 配置
- **THEN** 系统 SHALL 从 `$WORKSPACE_DIR/.prehen/config/` 解析上述结构化配置文件

#### Scenario: 配置目录不存在 models.yaml
- **WHEN** `$WORKSPACE_DIR/.prehen/config/` 不存在 `models.yaml`
- **THEN** 系统 SHALL 不将其视为缺失错误，并继续按 Provider/Agent 内模型配置运行

### Requirement: Global 资源回退与 workspace 覆盖
系统 MUST 支持 `$HOME/.prehen/global/config/` 作为结构化配置全局基线，并按“workspace 优先、global 回退”解析同名配置文件。

#### Scenario: workspace 存在同名配置文件
- **WHEN** workspace 与 global 同时存在 `providers.yaml` 或 `agents.yaml`
- **THEN** 系统 SHALL 优先使用 workspace 文件

#### Scenario: workspace 缺失配置文件
- **WHEN** workspace 缺失 `runtime.yaml` 或 `secrets.yaml` 且 global 存在对应文件
- **THEN** 系统 SHALL 回退使用 global 配置文件
