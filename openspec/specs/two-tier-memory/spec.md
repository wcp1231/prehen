## Requirements

### Requirement: Session 级 STM 管理
系统 MUST 为每个 session 维护独立 short-term memory（STM），包括对话缓冲、工作上下文与 token 预算。

#### Scenario: 会话执行中更新 STM
- **WHEN** 会话完成一次回合并产生新消息与工具 observation
- **THEN** 系统 SHALL 将新增上下文写入该 session 的 STM 并更新预算状态

### Requirement: 通用 LTM Adapter Contract
系统 MUST 定义 long-term memory（LTM）的通用接口契约，并允许本地或远端实现接入。

#### Scenario: LTM 接口兼容性 contract test（mock/stub）
- **WHEN** 测试环境使用 mock/stub adapters 分别实现同一组 LTM 接口
- **THEN** 上层编排逻辑 SHALL 在不修改调用代码的前提下通过同一 contract 完成读写与错误处理验证

### Requirement: LTM 接口先行而非具体实现
系统 MUST 在本次变更中仅落地 LTM 接口与调用边界，不实现具体检索与持久化逻辑。

#### Scenario: 当前阶段调用 LTM 能力
- **WHEN** Orchestrator 触发 LTM 读取或写入流程
- **THEN** 系统 SHALL 通过约定接口返回可诊断结果，并且 SHALL NOT 依赖已落地的具体 LTM 存储实现（以 contract test 覆盖兼容性）

### Requirement: Memory 读取策略
系统 MUST 采用“STM 主、LTM 补充”的读取策略，保证短期上下文优先。

#### Scenario: 生成回合上下文
- **WHEN** 系统为下一轮推理组装上下文
- **THEN** 系统 SHALL 先读取 STM，再按策略补充 LTM 结果

### Requirement: Memory 写入顺序与降级
系统 MUST 明确 memory 写入顺序，并在 LTM 失败时保证会话可继续。

#### Scenario: LTM 写入失败
- **WHEN** 会话结束回合后 LTM 写入返回错误
- **THEN** 系统 SHALL 保留 STM 更新结果并记录失败事件，而不阻塞会话后续执行
