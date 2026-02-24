## Context

当前 Prehen 是一个纯 Elixir 项目，通过 `mix escript.build` 生成 CLI 二进制，入口为 `Prehen.CLI.main/1`，走 `Client.Surface.run/2` 完成单轮对话。核心层已具备完整能力：多 session 管理、事件订阅（Registry-based）、session ledger 持久化与回放、ReAct 循环执行。

`Client.Surface` 已设计为统一多端接口（CLI/Web/Native），提供 `create_session`、`submit_message`、`subscribe_events`、`session_status`、`replay_session`、`stop_session` 等 API。当前仅 CLI 在使用 `run/2` 这条快捷路径。

事件系统通过 `Prehen.Events.ProjectionSupervisor` 基于 Elixir Registry 进行 dispatch，subscriber 收到 `{:session_event, record}` 消息。事件有 `seq` 序号和完整 envelope（`session_id`、`request_id`、`run_id`、`turn_id`、`at_ms`）。

## Goals / Non-Goals

**Goals:**

- 引入 Phoenix 作为 Transport 层，将 `Client.Surface` 暴露为 REST + WebSocket 接口
- 支持前端通过 WebSocket Channel 实时接收 streaming token、tool 调用过程、thinking 过程等事件
- 支持 WebSocket 断线重连后基于 `last_seq` 补缺丢失事件
- 新建 React SPA 前端（Bun），实现多轮对话、streaming 渲染、tool 调用可视化
- Web 和未来 Tauri 2 桌面端共用同一套 SPA + API

**Non-Goals:**

- 不做用户认证/鉴权（MVP 阶段后置）
- 不做 API Gateway 或反向代理层
- 不实现 Tauri 2 集成（本次仅为 Web 版本，架构上预留 Tauri 2 接入路径）
- 不改动 Prehen Core 层的 session/agent/memory/event 逻辑
- 不引入 Phoenix LiveView（前端为独立 SPA）
- 不做 Phoenix LiveDashboard（后续可选引入）

## Decisions

### Decision 1: Phoenix 直接嵌入现有 Mix 项目（非 Umbrella）

在 `lib/prehen_web/` 下新增 Phoenix 相关模块，不转换为 umbrella 项目。

**备选方案：**
- Umbrella project（`apps/prehen` + `apps/prehen_web`）— 隔离更好但改动大，当前规模不需要
- 独立 Phoenix 项目通过 HTTP 调用 Prehen — 增加部署复杂度，无法利用 BEAM 内进程通信

**理由：** 项目规模适中，`PrehenWeb` 是 Prehen Core 的薄包装层，直接嵌入最简单。后续规模增长可再拆分。

### Decision 2: Session CRUD 走 REST，实时事件走 Channel

```
REST API（无状态）                Channel（有状态连接）
──────────────────                ─────────────────────
POST   /api/sessions              join("session:<id>")
GET    /api/sessions              handle_in("submit", ...)
GET    /api/sessions/:id          push("event", ...)
DELETE /api/sessions/:id
GET    /api/sessions/:id/replay
GET    /api/agents
```

**备选方案：**
- 全部走 Channel（join 时创建 session）— join 做太多事，失败语义不清
- 全部走 REST + SSE — 无法利用 Phoenix Channel 的重连、心跳、multiplexing 能力

**理由：** CRUD 天然是 REST 语义；实时推送天然是 WebSocket 语义。关注点分离最清晰。

### Decision 3: Channel 统一 `"event"` push，不做事件类型映射

Channel 将所有事件以 `push(socket, "event", serialized_payload)` 推送，前端通过 `payload.type` 字段分发。

**备选方案：**
- 每种事件类型一个 push 名（`push("delta", ...)`, `push("tool_call", ...)`）— Channel 需维护映射表，新增事件类型要改 Channel

**理由：** Channel 保持为**薄透传层**，零翻译逻辑。新增事件类型时 Channel 代码无需改动，仅前端按需处理新 type。

### Decision 4: 重连补缺基于 `last_seq` + `replay_session`

前端 rejoin 时携带 `last_seq` 参数。Channel 调用 `Surface.replay_session` 过滤 `seq > last_seq` 的事件逐个 push，然后切换到实时订阅。

**理由：** 现有 session ledger 已支持 `seq` 编号和 `replay_session`，无需引入额外基础设施。

### Decision 5: EventSerializer 处理 Elixir → JSON 转换

新增 `PrehenWeb.EventSerializer` 模块，负责：

| Elixir 类型 | JSON 输出 |
|---|---|
| `{:ok, value}` | `{"status": "ok", "value": value}` |
| `{:error, reason}` | `{"status": "error", "reason": inspect(reason)}` |
| atom（如 `:content`） | string（`"content"`） |
| pid | 移除（不序列化进程标识） |
| 其他 map/list/string/number | 保持原样 |

**理由：** Elixir 事件包含 tuple、atom、pid 等非 JSON 类型，需要一个集中转换点。放在 Channel push 路径上，Core 层不受影响。

### Decision 6: 前端使用 React SPA + Bun

前端技术栈：

- **构建/运行**: Bun
- **框架**: React
- **Phoenix 对接**: `phoenix` npm 包（官方 Channel 客户端）
- **位置**: `frontend/` 目录

SPA 通过 HTTP + WebSocket 连接 Phoenix 后端。同一套代码未来可被 Tauri 2 直接包装（WebView 加载 SPA，Rust 侧管理 Elixir 进程生命周期，通过 localhost 通信）。

### Decision 7: Channel join 流程与 session 进程监控

```
join("session:<id>", %{"last_seq" => seq})
  1. Surface.resume_session(id) 或确认 session 存活
  2. Surface.subscribe_events(session_id) — Channel 进程注册到 Registry
  3. Process.monitor(session_pid) — 监控 session 进程
  4. 如果 last_seq > 0，replay 补缺事件
  5. reply {:ok, %{session_id: id}}

handle_info({:session_event, record}, socket)
  → EventSerializer.serialize(record)
  → push(socket, "event", serialized)
  → 更新 socket.assigns.last_seq

handle_info({:DOWN, _, :process, pid, reason}, socket)
  → push(socket, "event", %{type: "session.crashed", reason: ...})
  → {:stop, :normal, socket}
```

### Decision 8: 项目目录结构

```
lib/
├── prehen/                      # Core（不变）
│   ├── client/surface.ex
│   ├── agent/
│   ├── events/
│   └── ...
├── prehen_web/                  # 新增
│   ├── endpoint.ex
│   ├── router.ex
│   ├── channels/
│   │   ├── user_socket.ex
│   │   └── session_channel.ex
│   ├── controllers/
│   │   ├── session_controller.ex
│   │   └── agent_controller.ex
│   └── serializers/
│       └── event_serializer.ex
└── prehen.ex

frontend/                        # 新增
├── package.json
├── bun.lock
├── index.html
├── src/
│   ├── App.tsx
│   ├── hooks/
│   │   └── useSession.ts
│   ├── components/
│   │   ├── ChatView.tsx
│   │   └── ToolViewer.tsx
│   └── lib/
│       └── channel.ts
└── ...

config/
├── config.exs                   # 追加 Phoenix endpoint 配置
├── dev.exs                      # 开发环境配置
└── runtime.exs                  # 运行时配置
```

## Risks / Trade-offs

**[Phoenix 依赖体积]** → Phoenix 引入大量依赖（cowboy、plug、telemetry 等），增加编译时间和 release 体积。Mitigation: 仅引入必要依赖（`phoenix` + `phoenix_pubsub`），不引入 LiveView、Ecto、Mailer 等无关组件。

**[escript 兼容性]** → Phoenix Endpoint 需要 OTP application 启动，纯 escript 模式下能否共存需要验证。Mitigation: CLI 路径检测是否需要启动 Endpoint（仅 `prehen server` 命令启动 Phoenix，`prehen run` 保持现有 escript 行为）。

**[事件补缺窗口]** → 断线期间如果 session 完成并被清理，replay 可能失败。Mitigation: session ledger 文件持久化在磁盘，即使 session 进程结束，历史事件仍可回放。

**[Channel 进程与 session 进程生命周期不一致]** → 用户关闭浏览器后 Channel 进程终止，但 session 可能仍在执行。Mitigation: session 有 `idle_ttl` 机制自动清理；Channel terminate 时不主动 stop session，允许后续重连恢复。

**[CORS 安全]** → SPA 独立部署时需要跨域访问 Phoenix API。Mitigation: MVP 阶段配置宽松 CORS，生产环境收紧到指定 origin。

## Open Questions

- Phoenix Endpoint 端口策略：固定端口还是可配置？是否需要支持 Unix Socket？
- 前端路由策略：React Router 还是更轻量的方案？
- 前端状态管理：是否需要引入 Zustand/Jotai 等状态库，还是 React Context + useReducer 足够？
- `prehen server` 命令是否需要新增到 CLI，还是通过 `mix phx.server` / release 启动？
