## ADDED Requirements

### Requirement: 结构化配置域
系统 MUST 使用结构化配置域加载运行配置，并在 workspace/global 两级目录中解析以下文件：`providers.yaml`、`agents.yaml`、`runtime.yaml`、`secrets.yaml`。

#### Scenario: workspace 覆盖 global 配置
- **WHEN** `$WORKSPACE_DIR/.prehen/config/providers.yaml` 与 `$HOME/.prehen/global/config/providers.yaml` 同时存在同名 Provider
- **THEN** 系统 SHALL 优先使用 workspace 配置并覆盖 global 同名项

#### Scenario: workspace 缺失时回退 global
- **WHEN** workspace 下不存在某个配置文件且 global 下存在该文件
- **THEN** 系统 SHALL 回退读取 global 对应文件

### Requirement: Provider 模型目录（ID 与名称）
系统 MUST 允许在 Provider 配置中声明模型目录，并要求每个模型项至少包含 `id` 与 `name` 字段；系统 SHALL NOT 依赖独立 `models.yaml` 才能运行。

#### Scenario: OpenAI-compatible Provider 声明模型目录
- **WHEN** `providers.yaml` 中某个 `openai_compatible` Provider 配置了 `endpoint` 与 `models: [{id, name}]`
- **THEN** 系统 SHALL 可使用该目录中的 `model.id` 发起调用，并在需要展示时使用 `model.name`

#### Scenario: 未提供 models.yaml
- **WHEN** 配置目录不存在 `models.yaml`
- **THEN** 系统 SHALL 仍可完成配置加载与运行，不将其视为缺失错误

### Requirement: 请求级 Provider/模型参数注入
系统 MUST 以请求级方式注入 Provider 与模型参数（如 `api_key`、`base_url`、`temperature`、`max_tokens`），并 SHALL NOT 通过全局可变运行时配置共享这些参数。

#### Scenario: 并发会话使用不同 Provider 参数
- **WHEN** 两个会话并发执行且分别选择不同 endpoint 或 api_key
- **THEN** 系统 SHALL 确保各自请求使用各自参数，不发生跨会话参数污染

### Requirement: YAML 作为主配置格式
系统 MUST 以 YAML 作为结构化配置的规范格式输入，并在解析失败时返回可诊断错误。

#### Scenario: YAML 语法错误
- **WHEN** `providers.yaml` 或 `agents.yaml` 存在语法错误
- **THEN** 系统 SHALL 返回结构化配置错误，并包含文件路径与错误位置信息
