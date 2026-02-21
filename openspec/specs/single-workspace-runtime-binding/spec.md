## Requirements

### Requirement: 单进程单 workspace 绑定
系统 MUST 在进程启动阶段绑定一个且仅一个 `workspace` 目录，并在进程生命周期内维持该绑定不变。

#### Scenario: 进程启动时确定绑定目录
- **WHEN** 用户启动 Prehen 进程并传入 `--workspace /projects/ws-a`
- **THEN** 系统 SHALL 将 `/projects/ws-a` 设为该进程唯一绑定 workspace

#### Scenario: 未显式提供 workspace
- **WHEN** 用户启动 Prehen 进程且未提供 `--workspace`
- **THEN** 系统 SHALL 将 `$HOME/.prehen/workspace` 设为该进程唯一绑定 workspace

### Requirement: 后续请求复用已绑定 workspace
系统 MUST 在常规会话请求中复用进程已绑定 workspace，调用方 SHALL NOT 需要在每次请求里重复提供 `workspace` 参数。

#### Scenario: 创建后继续提交请求
- **WHEN** 会话已在绑定 workspace 中创建，客户端继续调用 `submit_message` 与 `await_result`
- **THEN** 系统 SHALL 使用进程已绑定 workspace 执行后续请求

### Requirement: workspace 覆盖冲突保护
系统 MUST 在调用方显式传入覆盖型 workspace 且与绑定目录不一致时返回 `workspace_mismatch` 错误，并拒绝该请求。

#### Scenario: 显式传入不同 workspace
- **WHEN** 进程已绑定 `/projects/ws-a`，调用方请求显式指定 `/projects/ws-b`
- **THEN** 系统 SHALL 返回 `workspace_mismatch` 错误并保持原绑定不变
