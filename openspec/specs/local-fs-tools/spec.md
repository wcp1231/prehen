## Requirements

### Requirement: LS 工具能力
系统 MUST 提供 `ls` 工具用于列出指定目录内容，并将结果返回给 Agent 作为 observation。

#### Scenario: 列出允许目录下的文件
- **WHEN** Agent 调用 `ls` 且参数 `path` 位于允许根目录内
- **THEN** 系统 SHALL 返回目录条目列表，并包含足够信息供后续决策使用

#### Scenario: 访问越界目录被拒绝
- **WHEN** Agent 调用 `ls` 且 `path` 规范化后位于允许根目录外
- **THEN** 系统 SHALL 拒绝执行并返回明确错误信息

### Requirement: READ 工具能力
系统 MUST 提供 `read` 工具用于读取文本文件，并支持限制读取范围或读取长度。

#### Scenario: 读取文本文件内容
- **WHEN** Agent 调用 `read` 读取允许路径下的文本文件
- **THEN** 系统 SHALL 返回文件内容文本片段供推理使用

#### Scenario: 读取内容超过限制时截断
- **WHEN** `read` 返回内容超过配置的 `max_bytes`
- **THEN** 系统 SHALL 返回被截断内容并附带截断提示

### Requirement: 工具参数与错误处理
系统 MUST 对工具输入参数进行验证，并以统一错误结构返回失败结果。

#### Scenario: 缺失必需参数
- **WHEN** Agent 调用工具时缺失 `path` 等必需参数
- **THEN** 系统 SHALL 返回参数校验错误并不执行文件系统操作

#### Scenario: 目标文件不存在
- **WHEN** Agent 调用 `read` 指向不存在的文件
- **THEN** 系统 SHALL 返回可诊断的失败结果且不中断整个 Agent 会话

### Requirement: 会话中断兼容语义
系统 MUST 在 steering 中断场景下保证工具调用可跳过且不会产生额外文件系统访问副作用。

#### Scenario: 工具调用被标记为 skipped
- **WHEN** 运行时因已排队 steering 消息而将某个 `ls/read` 调用标记为 skipped
- **THEN** 系统 SHALL 返回统一 skipped 结果，并且 SHALL NOT 执行实际文件系统读取或目录扫描
