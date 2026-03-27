defmodule Prehen.Gateway.SessionRegistry do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def put(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put, attrs})
  end

  def fetch(gateway_session_id) when is_binary(gateway_session_id) do
    GenServer.call(__MODULE__, {:fetch, gateway_session_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, attrs}, _from, state) do
    gateway_session_id = Map.fetch!(attrs, :gateway_session_id)
    updated = Map.put(state, gateway_session_id, Map.delete(attrs, :gateway_session_id))
    {:reply, :ok, updated}
  end

  def handle_call({:fetch, gateway_session_id}, _from, state) do
    case Map.fetch(state, gateway_session_id) do
      {:ok, session} -> {:reply, {:ok, session}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end
end
