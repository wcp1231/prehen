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

  def delete(gateway_session_id) when is_binary(gateway_session_id) do
    GenServer.call(__MODULE__, {:delete, gateway_session_id})
  end

  def fetch_worker(gateway_session_id) when is_binary(gateway_session_id) do
    GenServer.call(__MODULE__, {:fetch_worker, gateway_session_id})
  end

  def list_workers do
    GenServer.call(__MODULE__, :list_workers)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, attrs}, _from, state) do
    gateway_session_id = Map.fetch!(attrs, :gateway_session_id)
    updated =
      Map.update(
        state,
        gateway_session_id,
        Map.delete(attrs, :gateway_session_id),
        &Map.merge(&1, Map.delete(attrs, :gateway_session_id))
      )

    {:reply, :ok, updated}
  end

  def handle_call({:fetch, gateway_session_id}, _from, state) do
    case Map.fetch(state, gateway_session_id) do
      {:ok, session} -> {:reply, {:ok, session}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, gateway_session_id}, _from, state) do
    {:reply, :ok, Map.delete(state, gateway_session_id)}
  end

  def handle_call({:fetch_worker, gateway_session_id}, _from, state) do
    case Map.fetch(state, gateway_session_id) do
      {:ok, %{status: status}}
      when status in [:stopped, :crashed] ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{worker_pid: worker_pid}} when is_pid(worker_pid) ->
        if Process.alive?(worker_pid) do
          {:reply, {:ok, worker_pid}, state}
        else
          {:reply, {:error, :not_found}, state}
        end

      {:ok, _session} ->
        {:reply, {:error, :not_found}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_workers, _from, state) do
    workers =
      state
      |> Map.values()
      |> Enum.flat_map(fn
        %{status: status} when status in [:stopped, :crashed] ->
          []

        %{worker_pid: worker_pid} when is_pid(worker_pid) ->
          if Process.alive?(worker_pid), do: [worker_pid], else: []

        _session ->
          []
      end)

    {:reply, workers, state}
  end
end
