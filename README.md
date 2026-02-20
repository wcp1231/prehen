# Prehen

基于 Elixir 的通用 AI Agent MVP，当前实现聚焦：
- CLI 入口
- 单 Agent ReAct 循环
- `req_llm` 模型接入
- 本地工具 `ls` / `read`

## MVP Scope

已包含：
- `prehen run "<task>"` 命令执行
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
./prehen run "列出 lib 并读取 prehen.ex"
```

通过 Mix task：

```bash
mix prehen.run "列出 lib 并读取 prehen.ex"
```

## CLI Options

```text
prehen run "<task>" [--max-steps N] [--timeout-ms N] [--root-dir PATH] [--model NAME] [--trace-json]
```

## Configuration

支持通过命令行参数或环境变量配置：
- `PREHEN_MODEL`：模型名（默认 `openai:gpt-5-mini`，支持 `provider:model`；若仅填模型名会自动按 `openai:<model>` 处理）
- `PREHEN_API_KEY`：模型 API key
- `PREHEN_BASE_URL`：模型 base URL（可选）
- `PREHEN_MAX_STEPS`：最大执行步数（默认 `8`）
- `PREHEN_TIMEOUT_MS`：单次模型调用超时毫秒（默认 `15000`）
- `PREHEN_SESSION_IDLE_TTL_MS`：会话空闲回收阈值毫秒（默认 `300000`）
- `PREHEN_STM_BUFFER_LIMIT`：STM 对话缓冲区最大回合数（默认 `24`）
- `PREHEN_STM_TOKEN_BUDGET`：STM token 预算上限（默认 `8000`，估算值）
- `PREHEN_LTM_ADAPTER`：LTM adapter 名称（默认 `noop`，本次仅接口）
- `PREHEN_CAPABILITY_PACKS`：默认启用的 capability packs（逗号分隔，默认 `local_fs`）
- `PREHEN_WORKSPACE_CAPABILITY_ALLOWLIST`：workspace 允许的 capability packs（逗号分隔，默认 `local_fs`）
- `PREHEN_ROOT_DIR`：工具允许访问的根目录（默认当前目录）
- `PREHEN_READ_MAX_BYTES`：`read` 最大返回字节数（默认 `8192`）
- `PREHEN_TRACE_JSON`：是否输出 trace JSON（`true/false`）

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

## Client Surface

统一会话 API（用于 CLI/Web/Native）：
- `Prehen.Client.Surface.create_session/1`
- `Prehen.Client.Surface.submit_message/3`
- `Prehen.Client.Surface.session_status/1`
- `Prehen.Client.Surface.await_result/2`
- `Prehen.Client.Surface.stop_session/1`
- `Prehen.Client.Surface.subscribe_events/1`

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
