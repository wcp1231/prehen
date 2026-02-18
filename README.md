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
- `PREHEN_ROOT_DIR`：工具允许访问的根目录（默认当前目录）
- `PREHEN_READ_MAX_BYTES`：`read` 最大返回字节数（默认 `8192`）
- `PREHEN_TRACE_JSON`：是否输出 trace JSON（`true/false`）

## Tests

```bash
mix test
```
