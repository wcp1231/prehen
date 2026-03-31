defmodule Prehen.Agents.Registry do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Implementation
  alias Prehen.Agents.Profile
  alias Prehen.Config

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def all, do: GenServer.call(__MODULE__, :all)
  def fetch!(name), do: GenServer.call(__MODULE__, {:fetch!, name})
  def fetch_implementation!(name), do: GenServer.call(__MODULE__, {:fetch_implementation!, name})

  @impl true
  def init(opts) do
    profiles = Keyword.get(opts, :profiles, [])

    implementations =
      Keyword.get_lazy(opts, :implementations, fn ->
        Config.load().agent_implementations
      end)

    state = %{
      ordered: profiles,
      by_name: Map.new(profiles, fn %Profile{name: name} = profile -> {name, profile} end),
      implementations_ordered: implementations,
      implementations_by_name:
        Map.new(implementations, fn
          %Implementation{name: name} = implementation -> {name, implementation}
          implementation -> {implementation.name, implementation}
        end)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state.ordered, state}
  end

  def handle_call({:fetch!, name}, _from, state) do
    {:reply, Map.fetch!(state.by_name, to_string(name)), state}
  end

  def handle_call({:fetch_implementation!, name}, _from, state) do
    {:reply, Map.fetch!(state.implementations_by_name, to_string(name)), state}
  end
end
