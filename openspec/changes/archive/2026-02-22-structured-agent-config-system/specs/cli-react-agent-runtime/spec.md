## MODIFIED Requirements

### Requirement: CLI 任务执行入口
系统 MUST 提供 CLI 命令入口以接收自然语言任务并触发平台化运行时执行流程，并支持按 Agent 模板执行。

#### Scenario: 用户通过 Agent 模板执行任务
- **WHEN** 用户执行 `prehen run --agent coder "列出 lib 并读取 prehen.ex"`
- **THEN** 系统 SHALL 加载 `coder` 模板配置并基于该模板启动会话执行

#### Scenario: 用户通过 Agent 模板恢复历史会话
- **WHEN** 用户执行 `prehen run --agent coder --session-id s-123 "继续上次分析"`
- **THEN** 系统 SHALL 在恢复 `s-123` 后按 `coder` 模板配置继续执行后续回合

### Requirement: CLI 参数兼容与移除策略
系统 MUST 将已移除参数视为无效输入并返回参数错误。

#### Scenario: 用户提供已移除参数 --root-dir
- **WHEN** 用户执行 `prehen run "任务" --root-dir ./tmp`
- **THEN** 系统 SHALL 将该输入视为无效参数并返回参数错误

#### Scenario: 用户提供已移除参数 --model
- **WHEN** 用户执行 `prehen run --model openai:gpt-5-mini "任务"`
- **THEN** 系统 SHALL 将该输入视为无效参数并返回参数错误
