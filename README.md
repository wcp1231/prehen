# Prehen

基于 Elixir 的通用 AI Agent MVP，当前实现聚焦：
- CLI 入口
- 单 Agent ReAct 循环
- `req_llm` 模型接入
- 本地工具 `ls` / `read`

## MVP Scope

已包含：
- `prehen run --agent <name> "<task>"` 命令执行
- ReAct：`think -> action -> observation -> finish`
- `max_steps` 与 LLM timeout 控制
- 工具白名单与路径安全边界
- 结构化 trace 输出（可选 JSON）

未包含：
- 多 Agent 协作
- Web UI / HTTP API
- 向量记忆与数据库
- 通用 shell 执行工具

## Install

```bash
mix deps.get
```

## Run

通过 escript：

```bash
mix escript.build
./prehen run --agent coder "列出 lib 并读取 prehen.ex"
```

通过 Mix task：

```bash
mix prehen.run --agent coder "列出 lib 并读取 prehen.ex"
```

## CLI Options

```text
prehen run --agent NAME "<task>" [--workspace PATH] [--session-id ID] [--max-steps N] [--timeout-ms N] [--trace-json]
```

## Configuration

Provider / Model / Agent / Secret 通过结构化配置文件管理（不再使用环境变量承载这部分主配置）：
- `$WORKSPACE_DIR/.prehen/config/providers.yaml`
- `$WORKSPACE_DIR/.prehen/config/agents.yaml`
- `$WORKSPACE_DIR/.prehen/config/runtime.yaml`
- `$WORKSPACE_DIR/.prehen/config/secrets.yaml`
- `$HOME/.prehen/global/config/*` 作为 fallback（workspace 优先）

`models.yaml` 不是必需文件，模型目录直接定义在 `providers.yaml`（或 Agent 内联模型）中。

`providers.yaml` 示例：

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
    endpoint: https://example.com/v1
    credentials:
      api_key:
        secret_ref: providers.qwen_compat.api_key
    models:
      - id: qwen-plus
        name: Qwen Plus
```

`agents.yaml` 示例：

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

`secrets.yaml` 示例（单树结构，不按 dev/test/prod 分段）：

```yaml
secrets:
  providers:
    openai_official:
      api_key: sk-...
    qwen_compat:
      api_key: sk-...
```

目前仍可通过环境变量配置运行时通用项（如路径/超时/trace）：
- `PREHEN_WORKSPACE_DIR`
- `PREHEN_GLOBAL_DIR`
- `PREHEN_MAX_STEPS`
- `PREHEN_TIMEOUT_MS`
- `PREHEN_TRACE_JSON`
- `PREHEN_SESSION_IDLE_TTL_MS`
- `PREHEN_STM_BUFFER_LIMIT`
- `PREHEN_STM_TOKEN_BUDGET`
- `PREHEN_LTM_ADAPTER`
- `PREHEN_CAPABILITY_PACKS`
- `PREHEN_WORKSPACE_CAPABILITY_ALLOWLIST`
- `PREHEN_READ_MAX_BYTES`

workspace 目录结构：

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

- tools 允许访问整个 `$WORKSPACE_DIR`，包括 `$WORKSPACE_DIR/.prehen`。
- 同一进程绑定一个 workspace；需要管理多个 workspace 时请启动多个进程。

## Trace JSON Schema

`--trace-json` 输出统一事件数组。每个事件包含 typed envelope 字段：
- `type`
- `at_ms`
- `source`
- `schema_version`（当前为 `2`）
- correlation 字段：`session_id`、`request_id`、`run_id`、`turn_id`（按事件类型可选附带）

示例：

```json
[
  {
    "type": "ai.request.started",
    "at_ms": 1730000000000,
    "source": "prehen.session",
    "schema_version": 2,
    "session_id": "session_1",
    "request_id": "request_2",
    "run_id": "run_3",
    "turn_id": 1,
    "query": "列出 lib"
  }
]
```

## Migration Policy

- 本项目按一次性切换策略演进，不维护长期 compat mode 双轨路径。
- `trace_json` 已收敛为当前 schema（`schema_version: 2`），不再输出旧字段映射。
- `--model` 已移除；CLI 通过 `--agent` 选择模板。

## Model Fallback

- 每次 LLM 请求按 `primary + fallback_models` 候选链执行。
- 回退触发依据 `fallback_models[*].on_errors`。
- 认证类错误默认不自动回退。
- trace 中可观测事件：`ai.model.selected`、`ai.model.fallback`、`ai.model.exhausted`。

## Client Surface

统一会话 API（用于 CLI/Web/Native）：
- `Prehen.Client.Surface.create_session/1`
- `Prehen.Client.Surface.resume_session/2`
- `Prehen.Client.Surface.submit_message/3`
- `Prehen.Client.Surface.session_status/1`
- `Prehen.Client.Surface.await_result/2`
- `Prehen.Client.Surface.stop_session/1`
- `Prehen.Client.Surface.subscribe_events/1`

## Session Ledger

- Session 历史事实源为 `session_id.jsonl`（默认目录 `$HOME/.prehen/workspace/.prehen/sessions`）。
- `Conversation.Store` 采用 ledger-first：先持久化、再发布 projection。
- 回合完成事件（`ai.session.turn.completed`）会触发 durability checkpoint（`file.sync`）。
- 恢复会话通过重放当前绑定 workspace 下的 ledger 实现，恢复成功会发出 `ai.session.recovered`。

## Security (MVP)

- 当前 MVP 阶段客户端采用直连接入，不内置认证与鉴权。
- 认证、鉴权与更细粒度安全策略将在后续迭代补齐。

## Architecture Docs

- 当前实现架构（as-is）：`docs/architecture/current-system.md`
- 变更提案与目标设计（to-be）：`openspec/changes/`

## Tests

```bash
mix test
```
