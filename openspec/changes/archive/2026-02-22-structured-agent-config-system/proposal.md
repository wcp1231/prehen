## Why

当前配置主要依赖环境变量和 `runtime.json` 平面字段，存在以下问题：

- 无法结构化表达多 Provider、多模型与模型参数。
- 无法表达“按 Agent 模板执行”的配置复用模式。
- 密钥管理缺少显式的引用机制，配置与密钥边界不清晰。
- LLM Provider 配置通过全局运行时状态注入，不适合并发会话下的多配置隔离。

为支持可维护的多模型、多 Agent、可扩展功能配置，需要引入结构化配置系统，并将密钥管理与运行参数管理分离。

## What Changes

- 引入结构化配置文件（以 YAML 为主）并落地到现有 workspace/global 配置分层：
  - `$WORKSPACE_DIR/.prehen/config/providers.yaml`
  - `$WORKSPACE_DIR/.prehen/config/agents.yaml`
  - `$WORKSPACE_DIR/.prehen/config/runtime.yaml`
  - `$WORKSPACE_DIR/.prehen/config/secrets.yaml`
  - `$HOME/.prehen/global/config/*` 作为 fallback
- `providers.yaml` 支持两类 Provider：
  - 官方 Provider（如 OpenAI/Anthropic）
  - OpenAI-compatible Provider（可配置 endpoint）
- Provider 下的模型目录支持 `id + name`（并可附带默认参数）。
- `agents.yaml` 支持 Agent 模板，包含：
  - `name` / `description` / `system_prompt`
  - `capability_packs`
  - 主模型配置（可引用 Provider 模型，也可 Agent 内联）
  - 模型参数（如 `temperature`、`max_tokens`）
  - 备用模型列表与触发条件
- 引入 `secret_ref` 机制，配置文件通过引用读取密钥，不要求将密钥明文写入主配置。
- CLI 与 Surface 增加 Agent 入口（`Agent` 命名），使用时可“指定 agent + 输入”执行。
- 采用 Route B：LLM 调用改为“每次请求携带配置参数”，不再依赖全局 mutable Provider 注入。
- 明确不引入 `models.yaml`：模型配置只放在 `providers.yaml` 或 `agents.yaml`。

## Capabilities

### New Capabilities

- `structured-agent-config-system`: 定义 Provider/Agent/Runtime/Secret 的结构化配置与解析规则。
- `provider-secret-reference`: 定义 `secret_ref` 引用语义、来源优先级与错误行为。
- `agent-template-execution`: 定义“按 Agent 模板执行”的运行时 contract。

### Modified Capabilities

- `cli-react-agent-runtime`: 新增 `Agent` 入口参数语义，支持模板化运行。
- `client-surface-contract`: 增加 Agent 模板调用输入，并统一错误输出。
- `workspace-directory-layout`: 在 `config/` 子目录下补充结构化配置文件约定。

## Impact

- 受影响模块（预期）：
  - `Prehen.Config`
  - `Prehen.CLI`
  - `Prehen.Client.Surface`
  - `Prehen.Agent.Runtime`
  - `Prehen.Agent.Session`
  - `Prehen.Agent.Backends.JidoAI`
  - `Prehen.Agent.Strategies.ReactExt`
- 配置与运行时影响：
  - 主配置来源从“环境变量中心化”转向“结构化文件中心化”。
  - 密钥通过 `secret_ref` 解析，主配置不直接承载敏感值。
  - 并发会话下支持不同 Agent/Provider 运行参数隔离（请求级参数注入）。
- CLI/API 影响：
  - 增加 `Agent` 模板入口；
  - 旧的单模型环境变量路径进入兼容过渡或弃用流程（以实现阶段策略为准）。
