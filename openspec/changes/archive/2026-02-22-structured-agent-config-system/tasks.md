## 1. 配置文件体系与解析框架

- [x] 1.1 引入 YAML 配置解析能力，并建立统一配置加载入口（workspace 优先、global 回退、defaults 兜底）
- [x] 1.2 在 `Prehen.Config` 中新增结构化配置加载流程：`providers.yaml`、`agents.yaml`、`runtime.yaml`、`secrets.yaml`
- [x] 1.3 明确并实现“无 `models.yaml`”策略：模型只来自 `providers.yaml` 或 `agents.yaml`
- [x] 1.4 为配置加载增加结构化错误（文件路径、字段路径、错误原因）

## 2. Provider 配置与模型目录

- [x] 2.1 定义 Provider 配置 schema，支持 `official` 与 `openai_compatible` 两类 Provider
- [x] 2.2 定义 Provider 下模型目录 schema，要求每项至少包含 `id` 与 `name`
- [x] 2.3 支持 Provider 模型默认参数（如 `default_params.temperature/max_tokens`）
- [x] 2.4 增加 Provider 配置校验：未知 kind、缺失 endpoint、模型字段不合法等错误分支

## 3. Secret 引用机制（secret_ref）

- [x] 3.1 实现 `secret_ref` 解析器，从 `secrets.yaml` 读取并注入运行时凭证
- [x] 3.2 实现 secrets 优先级：workspace secrets > global secrets
- [x] 3.3 固化 secrets 单树结构，不支持按 `dev/test/prod` 环境分段
- [x] 3.4 增加错误语义与测试：`secret_ref_not_found`、`secret_value_invalid`、`provider_credentials_missing`

## 4. Agent 模板解析与参数合并

- [x] 4.1 定义 Agent 模板 schema：`name/description/system_prompt/capability_packs/model/fallback_models`
- [x] 4.2 支持 Agent 主模型与 fallback 模型参数配置（`temperature`、`max_tokens` 等）
- [x] 4.3 实现参数合并顺序：Provider 模型默认参数 < Agent 参数 < 调用时覆盖
- [x] 4.4 增加模板解析错误与测试：`agent_template_not_found`、字段类型错误、引用失效

## 5. CLI 与 Surface/Runtime Contract 改造

- [x] 5.1 CLI 增加 `--agent <name>` 参数，并接入模板化执行路径
- [x] 5.2 CLI 移除旧 `--model` 参数并提供明确错误提示
- [x] 5.3 更新 Surface/Runtime 入口，支持 `agent` 选项并对未知模板返回统一错误结构
- [x] 5.4 调整 README 与 CLI usage 文案，统一为 Agent 模板入口

## 6. Route B 执行面改造（请求级注入）

- [x] 6.1 移除当前全局 Provider 注入依赖（不再以全局 mutable 配置承载会话级参数）
- [x] 6.2 在 ReAct 执行链中注入请求级 LLM 选项（`api_key/base_url/provider_options/model params`）
- [x] 6.3 增加 Prehen 侧 directive/adapter 扩展，确保 `ReqLLM` 调用接收请求级参数
- [x] 6.4 验证并发会话隔离：不同会话不同 Provider 配置互不污染

## 7. 模型回退（fallback）策略

- [x] 7.1 实现主模型 + fallback 候选链执行逻辑
- [x] 7.2 实现按 `on_errors` 分类触发回退（如 `timeout/rate_limit/provider_error`）
- [x] 7.3 明确认证类错误不自动回退，并补齐测试覆盖
- [x] 7.4 增加回退过程事件或可观测字段（如 selected/fallback/exhausted）

## 8. 测试、回归与文档收尾

- [x] 8.1 增加配置解析测试：YAML 解析、schema 校验、workspace/global 回退、无 `models.yaml` 路径
- [x] 8.2 增加 secrets 测试：`secret_ref` 成功、缺失、无效类型、优先级覆盖
- [x] 8.3 增加 Agent 模板执行测试：主模型、参数覆盖、fallback 行为、错误语义
- [x] 8.4 增加 CLI 测试：`--agent` 成功路径、`--model` 移除错误路径
- [x] 8.5 更新 `README.md` 与架构文档，记录结构化配置、Agent 入口与 Route B 约束
