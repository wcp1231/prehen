## MODIFIED Requirements

### Requirement: LS 工具能力
系统 MUST 以可插拔 tool pack 形式提供 `ls` 工具能力，并将执行结果返回给 Agent 作为 observation；`ls` 的允许根目录 SHALL 为进程绑定的 workspace 根目录。

#### Scenario: 列出允许目录下的文件
- **WHEN** Agent 在已启用 `local-fs` capability 的会话中调用 `ls` 且参数 `path` 位于绑定 workspace 根目录内
- **THEN** 系统 SHALL 返回目录条目列表，并包含足够信息供后续决策使用

#### Scenario: 列出 `.prehen` 子目录
- **WHEN** Agent 调用 `ls` 且目标路径位于 `$WORKSPACE_DIR/.prehen` 内
- **THEN** 系统 SHALL 允许访问并返回对应目录条目

#### Scenario: 访问越界目录被拒绝
- **WHEN** Agent 调用 `ls` 且 `path` 规范化后位于绑定 workspace 根目录外
- **THEN** 系统 SHALL 拒绝执行并返回明确错误信息

### Requirement: READ 工具能力
系统 MUST 以可插拔 tool pack 形式提供 `read` 工具能力，用于读取文本文件并支持限制读取范围或读取长度；`read` 的允许根目录 SHALL 为进程绑定的 workspace 根目录。

#### Scenario: 读取文本文件内容
- **WHEN** Agent 调用 `read` 读取绑定 workspace 允许路径下的文本文件
- **THEN** 系统 SHALL 返回文件内容文本片段供推理使用

#### Scenario: 读取 `.prehen` 内文件
- **WHEN** Agent 调用 `read` 读取 `$WORKSPACE_DIR/.prehen` 下的文本文件
- **THEN** 系统 SHALL 允许读取并返回内容

#### Scenario: 读取内容超过限制时截断
- **WHEN** `read` 返回内容超过配置的 `max_bytes`
- **THEN** 系统 SHALL 返回被截断内容并附带截断提示
