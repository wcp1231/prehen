defmodule Prehen.Observability.TraceCollector do
  @moduledoc false

  use GenServer

  alias Prehen.Agent.EventBridge

  @max_events_per_session 200

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:record, normalize(event)})
  catch
    :exit, _reason -> :ok
  end

  def record_sync(event) when is_map(event) do
    GenServer.call(__MODULE__, {:record_sync, normalize(event)})
  catch
    :exit, _reason -> :ok
  end

  def for_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:for_session, session_id})
  catch
    :exit, _reason -> {:ok, []}
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:record, %{session_id: session_id} = event}, state) do
    events =
      state
      |> Map.get(session_id, [])
      |> Kernel.++([event])
      |> trim()

    {:noreply, Map.put(state, session_id, events)}
  end

  def handle_cast({:record, _event}, state), do: {:noreply, state}

  @impl true
  def handle_call({:for_session, session_id}, _from, state) do
    {:reply, {:ok, Map.get(state, session_id, [])}, state}
  end

  def handle_call({:record_sync, %{session_id: session_id} = event}, _from, state) do
    events =
      state
      |> Map.get(session_id, [])
      |> Kernel.++([event])
      |> trim()

    {:reply, :ok, Map.put(state, session_id, events)}
  end

  def handle_call({:record_sync, _event}, _from, state) do
    {:reply, :ok, state}
  end

  defp normalize(%{type: type} = event) when is_binary(type) do
    session_id =
      Map.get(event, :session_id) ||
        Map.get(event, "session_id") ||
        Map.get(event, :gateway_session_id) ||
        Map.get(event, "gateway_session_id")

    payload =
      event
      |> Map.drop([:type, "type", :session_id, "session_id", :gateway_session_id, "gateway_session_id"])
      |> Enum.into(%{}, fn {k, v} -> {normalize_key(k), v} end)
      |> Map.put_new(:session_id, session_id)
      |> Map.put_new(:gateway_session_id, session_id)

    EventBridge.project(type, payload, source: "prehen.gateway")
  end

  defp normalize(event), do: event

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      _ -> key
    end
  end

  defp normalize_key(key), do: key

  defp trim(events) do
    overflow = length(events) - @max_events_per_session
    if overflow > 0, do: Enum.drop(events, overflow), else: events
  end
end
