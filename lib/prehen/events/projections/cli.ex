defmodule Prehen.Events.Projections.CLI do
  @moduledoc false

  use GenServer

  @default_topic :canonical_event
  @default_registry Prehen.Events.ProjectionRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec events(String.t()) :: [map()]
  def events(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:events, session_id})
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, @default_registry)
    topic = Keyword.get(opts, :topic, @default_topic)
    _ = Registry.register(registry, topic, :cli_projection)
    {:ok, %{events: %{}}}
  end

  @impl true
  def handle_call({:events, session_id}, _from, state) do
    {:reply, Map.get(state.events, session_id, []), state}
  end

  @impl true
  def handle_info({:projection_event, record}, state) do
    session_id = Map.get(record, :session_id)

    next_events =
      if is_binary(session_id) do
        Map.update(state.events, session_id, [record], fn existing ->
          existing ++ [record]
        end)
      else
        state.events
      end

    {:noreply, %{state | events: next_events}}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
