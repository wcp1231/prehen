defmodule Prehen.Events.Projections.Logger do
  @moduledoc false

  use GenServer

  require Logger

  @default_topic :canonical_event
  @default_registry Prehen.Events.ProjectionRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, @default_registry)
    topic = Keyword.get(opts, :topic, @default_topic)
    _ = Registry.register(registry, topic, :logger_projection)

    {:ok,
     %{
       enabled?: Application.get_env(:prehen, :projection_log_events, false)
     }}
  end

  @impl true
  def handle_info({:projection_event, record}, %{enabled?: true} = state) do
    if record.kind == :event and is_binary(record.type) and record.type != "" do
      Logger.debug("projection event type=#{record.type} session=#{Map.get(record, :session_id)}")
    end

    {:noreply, state}
  end

  def handle_info({:projection_event, _record}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}
end
