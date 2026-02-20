defmodule Prehen.Memory.LTMAdapters do
  @moduledoc false

  use GenServer

  alias Prehen.Memory.LTM.NoopAdapter

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec register(atom(), module()) :: :ok | {:error, :invalid_adapter}
  def register(name, adapter) when is_atom(name) and is_atom(adapter) do
    GenServer.call(__MODULE__, {:register, name, adapter})
  end

  @spec fetch(atom()) :: {:ok, module()} | {:error, :not_found}
  def fetch(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:fetch, name})
  end

  @impl true
  def init(state) do
    {:ok, Map.put_new(state, :noop, NoopAdapter)}
  end

  @impl true
  def handle_call({:register, name, adapter}, _from, state) do
    if valid_adapter?(adapter) do
      {:reply, :ok, Map.put(state, name, adapter)}
    else
      {:reply, {:error, :invalid_adapter}, state}
    end
  end

  def handle_call({:fetch, name}, _from, state) do
    case Map.fetch(state, name) do
      {:ok, adapter} -> {:reply, {:ok, adapter}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp valid_adapter?(adapter) when is_atom(adapter) do
    function_exported?(adapter, :get, 2) and function_exported?(adapter, :put, 3)
  end
end
