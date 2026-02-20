defmodule Prehen.Events.Projections.Metrics do
  @moduledoc false

  use GenServer

  @default_topic :canonical_event
  @default_registry Prehen.Events.ProjectionRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, @default_registry)
    topic = Keyword.get(opts, :topic, @default_topic)
    _ = Registry.register(registry, topic, :metrics_projection)
    {:ok, %{total: 0, by_kind: %{}, by_type: %{}}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:projection_event, record}, state) do
    kind = normalize_kind(Map.get(record, :kind))
    type = Map.get(record, :type, "unknown")

    next_state = %{
      total: state.total + 1,
      by_kind: Map.update(state.by_kind, kind, 1, &(&1 + 1)),
      by_type: Map.update(state.by_type, type, 1, &(&1 + 1))
    }

    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp normalize_kind(kind) when kind in [:event, :message, :record], do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    case kind do
      "event" -> :event
      "message" -> :message
      "record" -> :record
      _ -> :record
    end
  end

  defp normalize_kind(_), do: :record
end
