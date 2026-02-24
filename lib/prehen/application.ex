defmodule Prehen.Application do
  @moduledoc """
  Prehen 应用根监督树。

  中文：
  - 统一启动平台核心子系统（agent/session/memory/store/projection/tools）。
  - 提供健康检查快照，便于定位子系统状态。

  English:
  - Root supervision tree for platform subsystems.
  - Boots agent/session/memory/store/projection/tools components.
  - Exposes health snapshots for operational diagnostics.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Prehen.PubSub},
      {Prehen.Agent.JidoRuntimeStarter, []},
      {Prehen.Agent.Supervisor, []},
      {Prehen.Tools.PackRegistry, []},
      {Prehen.Workspace.SessionSupervisor, []},
      {Prehen.Workspace.SessionManager, []},
      {Prehen.Memory.Supervisor, []},
      {Prehen.Conversation.Store, []},
      {Prehen.Events.ProjectionSupervisor, []},
      PrehenWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Prehen.Supervisor]
    Logger.info("prehen supervision tree booting (#{length(children)} children)")
    Supervisor.start_link(children, opts)
  end

  @spec health() :: map()
  def health do
    %{
      jido_runtime: module_health(Prehen.JidoRuntime),
      agent_supervisor: supervisor_health(Prehen.Agent.Supervisor),
      tool_pack_registry: module_health(Prehen.Tools.PackRegistry),
      session_supervisor: supervisor_health(Prehen.Workspace.SessionSupervisor),
      session_manager: module_health(Prehen.Workspace.SessionManager),
      memory_supervisor: supervisor_health(Prehen.Memory.Supervisor),
      conversation_store: module_health(Prehen.Conversation.Store),
      projection_supervisor: supervisor_health(Prehen.Events.ProjectionSupervisor)
    }
  end

  defp module_health(module) do
    case Process.whereis(module) do
      nil -> %{status: :down}
      pid -> %{status: :up, pid: pid}
    end
  end

  defp supervisor_health(module) do
    case Process.whereis(module) do
      nil ->
        %{status: :down}

      _pid ->
        %{status: :up, children: Supervisor.count_children(module)}
    end
  rescue
    _ -> %{status: :up}
  end
end
