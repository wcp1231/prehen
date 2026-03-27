defmodule Prehen.Agents.Registry do
  @moduledoc false

  use GenServer

  alias Prehen.Agents.Profile

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def all, do: GenServer.call(__MODULE__, :all)
  def fetch!(name), do: GenServer.call(__MODULE__, {:fetch!, name})

  @impl true
  def init(opts) do
    profiles = Keyword.get(opts, :profiles, [])

    state = %{
      ordered: profiles,
      by_name: Map.new(profiles, fn %Profile{name: name} = profile -> {name, profile} end)
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
end
