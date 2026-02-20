defmodule Prehen.Events.ProjectionSupervisor do
  @moduledoc """
  事件投影监督器与发布中心。

  中文：
  - 管理 projection 子进程（CLI/Logger/Metrics）。
  - 统一发布 canonical records 到全局 topic 与 session topic。
  - 提供 session 级订阅接口给客户端直连接入。

  English:
  - Supervisor and publish hub for projection consumers.
  - Broadcasts canonical records to global and per-session topics.
  - Exposes session-scoped subscription for direct client integrations.
  """

  use Supervisor

  @registry Prehen.Events.ProjectionRegistry
  @topic :canonical_event

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec publish(map()) :: :ok
  def publish(record) when is_map(record) do
    if Process.whereis(@registry) do
      Registry.dispatch(@registry, @topic, fn entries ->
        Enum.each(entries, fn {pid, _meta} ->
          send(pid, {:projection_event, record})
        end)
      end)

      session_id = Map.get(record, :session_id)

      if is_binary(session_id) and session_id != "" do
        session_topic = {:session, session_id}

        Registry.dispatch(@registry, session_topic, fn entries ->
          Enum.each(entries, fn {pid, _meta} ->
            send(pid, {:session_event, record})
          end)
        end)
      end
    end

    :ok
  end

  @spec subscribe(String.t()) ::
          {:ok, %{session_id: String.t()}} | {:error, :registry_unavailable}
  def subscribe(session_id) when is_binary(session_id) do
    if Process.whereis(@registry) do
      {:ok, _} = Registry.register(@registry, {:session, session_id}, :client)
      {:ok, %{session_id: session_id}}
    else
      {:error, :registry_unavailable}
    end
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :duplicate, name: @registry},
      {Prehen.Events.Projections.CLI, [registry: @registry, topic: @topic]},
      {Prehen.Events.Projections.Logger, [registry: @registry, topic: @topic]},
      {Prehen.Events.Projections.Metrics, [registry: @registry, topic: @topic]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
