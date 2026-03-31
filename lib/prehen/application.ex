defmodule Prehen.Application do
  @moduledoc """
  Prehen 应用根监督树。

  中文：
  - 统一启动当前 Gateway MVP 所需的核心子系统。
  - 提供健康检查快照，便于定位子系统状态。

  English:
  - Root supervision tree for platform subsystems.
  - Boots the core subsystems required by the current gateway MVP.
  - Exposes health snapshots for operational diagnostics.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    config = Prehen.Config.load()

    children = [
      {Phoenix.PubSub, name: Prehen.PubSub},
      {Prehen.Gateway.Supervisor, gateway_opts(config)},
      {Prehen.Observability.TraceCollector, []},
      PrehenWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Prehen.Supervisor]
    Logger.info("prehen supervision tree booting (#{length(children)} children)")
    Supervisor.start_link(children, opts)
  end

  @doc false
  def gateway_opts(config) when is_map(config) do
    [
      agent_profiles: Map.get(config, :agent_profiles, []),
      agent_implementations: Map.get(config, :agent_implementations, [])
    ]
  end

  @spec health() :: map()
  def health do
    %{
      gateway_supervisor: supervisor_health(Prehen.Gateway.Supervisor),
      agent_registry: module_health(Prehen.Agents.Registry),
      trace_collector: module_health(Prehen.Observability.TraceCollector)
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
