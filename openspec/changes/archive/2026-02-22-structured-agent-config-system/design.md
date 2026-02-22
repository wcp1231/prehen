## Context

现有系统已具备 workspace/global 配置分层，但配置内容仍以 `runtime.json` 平面键为主，无法描述：

- Provider 级模型目录（含模型 ID 与展示名）
- Agent 模板级模型参数与 fallback 策略
- 密钥引用与配置解耦
- 并发会话下的请求级 Provider 参数隔离

同时，当前 LLM 调用路径存在全局可变配置注入，和“多配置并发执行”目标冲突。

本设计将按 Route B 完整改造：配置结构化 + 密钥引用化 + LLM 请求参数作用域化。

## Goals / Non-Goals

**Goals**

- 用结构化配置替代环境变量中心化管理。
- Provider 模型目录支持 `id + name`，并可定义模型默认参数。
- Agent 模板可配置模型参数（如 `temperature`、`max_tokens`）与备用模型。
- 支持 `secret_ref`，将密钥从主配置中剥离。
- LLM 调用改为请求级参数注入，消除全局配置污染。
- 新增 `Agent` 入口：运行时通过模板名加载并执行。
- 保持 workspace 优先、global fallback 的配置解析语义。

**Non-Goals**

- 不引入 `models.yaml` 独立文件。
- 不在本次实现外部密钥管理器（Vault/KMS）插件。
- 不在本次实现 GUI 配置界面。

## High-Level Architecture

```text
                        CLI / Surface
                             |
                     agent name + input
                             |
                             v
                    Config Resolution Layer
         (providers.yaml + agents.yaml + runtime.yaml + secrets.yaml)
                             |
                             v
                     Resolved Agent Runtime
      (model candidates + per-call params + capability packs + prompts)
                             |
                             v
                  Session / Strategy (ReAct wrapper)
                             |
                   rewrite LLM directives with
                  request-scoped provider options
                             |
                             v
                        ReqLLM call
         (model, api_key, base_url, provider_options, params...)
```

## Decision 1: 配置格式与文件布局

**选择**

- 采用 YAML 作为主配置格式。
- 配置文件位于 `config/`：
  - `providers.yaml`
  - `agents.yaml`
  - `runtime.yaml`
  - `secrets.yaml`
- 不引入 `models.yaml`。

**理由**

- YAML 对模板类与多层结构更友好，可读性高。
- 与用户确认一致，且避免单独模型文件带来的跨文件跳转成本。

**备选方案**

- TOML/JSONC：可作为后续扩展输入格式，但本次不并行引入多格式解析复杂度。

## Decision 2: Provider 配置模型目录（id + name）

**选择**

- 模型目录挂在 Provider 下；每个模型至少包含 `id` 与 `name`。
- 可选 `default_params`（如 `temperature/max_tokens`）作为该模型默认值。

**示例**

```yaml
providers:
  openai_official:
    kind: official
    provider: openai
    credentials:
      api_key:
        secret_ref: providers.openai_official.api_key
    models:
      - id: gpt-5-mini
        name: GPT-5 Mini
        default_params:
          temperature: 0.2
          max_tokens: 4096

  qwen_compat:
    kind: openai_compatible
    provider: openai
    endpoint: https://dashscope.aliyuncs.com/compatible-mode/v1
    credentials:
      api_key:
        secret_ref: providers.qwen_compat.api_key
    models:
      - id: qwen-plus
        name: Qwen Plus
```

## Decision 3: Agent 模板配置模型与参数

**选择**

- Agent 模板支持：
  - `name/description/system_prompt`
  - `capability_packs`
  - `model`（主模型）
  - `fallback_models`（备用模型）
- `model` / `fallback_models` 可配置参数（如 `temperature`、`max_tokens`）。
- 模型可通过两种方式指定：
  - 通过 `provider_ref + model_id` 引用 Provider 目录
  - Agent 内联模型定义（用于小范围覆盖）

**示例**

```yaml
agents:
  coder:
    name: Coder
    description: Code-focused assistant
    system_prompt: |
      You are Prehen Coder.
    capability_packs: [local_fs]
    model:
      provider_ref: openai_official
      model_id: gpt-5-mini
      params:
        temperature: 0.1
        max_tokens: 6000
    fallback_models:
      - provider_ref: qwen_compat
        model_id: qwen-plus
        on_errors: [timeout, rate_limit, provider_error]
        params:
          temperature: 0.1
          max_tokens: 6000
```

## Decision 4: Secret 引用机制（secret_ref）

**选择**

- 敏感值通过 `secret_ref` 引用，不在主配置文件明文出现。
- `secrets.yaml` 保存密钥数据；按 workspace/global 两级解析。
- 解析优先级：workspace secrets > global secrets。

**示例**

```yaml
secrets:
  providers:
    openai_official:
      api_key: sk-...
    qwen_compat:
      api_key: sk-...
```

**错误语义**

- `secret_ref_not_found`
- `secret_value_invalid`
- `provider_credentials_missing`

## Decision 5: 配置解析优先级与参数合并

**选择**

- 总体优先级：
  1) CLI/调用参数
  2) workspace 配置
  3) global 配置
  4) defaults
- 参数合并顺序（后者覆盖前者）：
  1) Provider 模型 `default_params`
  2) Agent `model.params`
  3) 调用时覆盖参数（若提供）

## Decision 6: Route B 的执行面改造（请求级注入）

**选择**

- 废弃当前“启动会话时写全局 Provider 配置”的做法。
- 在 ReAct 执行路径上注入请求级 LLM 选项（`api_key/base_url/provider_options/params`）。
- 对每次 LLM 请求使用独立配置，不写全局 `Application.put_env`。

**落地方式**

- 在 `Prehen.Agent.Strategies.ReactExt` 中对 LLM directive 做重写：
  - 保留既有 ReAct 状态机行为；
  - 将解析后的请求级 Provider 选项附加到可执行 directive；
  - 由 Prehen 自定义 directive 执行 `ReqLLM.stream_text/3`。

**收益**

- 同进程并发会话可使用不同 Provider/endpoint/密钥组合，互不污染。

## Decision 7: Fallback 模型策略

**选择**

- 为每次 LLM 调用构建候选链：`[primary | fallback_models]`。
- 仅在匹配 `on_errors` 的错误类别时切换下一候选（如 `timeout/rate_limit/provider_error`）。
- 认证类错误（如 key 无效）默认不做自动 fallback（避免掩盖配置错误）。

**事件约定（建议）**

- `ai.model.selected`
- `ai.model.fallback`
- `ai.model.exhausted`

## Decision 8: Agent 入口 contract

**选择**

- CLI 新增 `--agent <name>`。
- Runtime/Surface 接口新增 `agent` 选项。
- 当 `agent` 指定时，系统按模板解析并执行；无 `agent` 时走兼容路径。

## Risks / Trade-offs

- [Risk] YAML 引入新解析依赖，增加配置加载复杂度。  
  Mitigation：引入严格 schema 校验与错误定位（文件 + 路径 + 行号）。

- [Risk] Route B 需要调整策略/指令执行链，改动面较大。  
  Mitigation：先保持状态机不变，仅替换 LLM directive 注入与执行层。

- [Risk] fallback 策略若边界不清，可能导致“意外换模”。  
  Mitigation：默认最小自动切换集合，显式 `on_errors` 控制。

- [Risk] secrets 文件误配置会导致运行失败。  
  Mitigation：启动期预检 + `prehen config validate`（后续任务）+ 清晰错误码。

## Migration Plan

1. 引入配置域与解析器（providers/agents/runtime/secrets）。
2. 新增 `Agent` 模板解析与运行入口。
3. 在执行链上完成 Route B 的请求级注入，移除全局注入依赖。
4. 增加 fallback 选择逻辑与事件输出。
5. 更新 README/CLI 文档与测试矩阵。

## Resolved Decisions

- `secrets.yaml` 不支持按环境分段（如 `dev/test/prod`），采用单一配置树。
- 移除旧 `--model` CLI 参数；模板化配置发布后，CLI 通过 `--agent` 选择执行模板。
