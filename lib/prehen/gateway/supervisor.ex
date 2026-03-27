defmodule Prehen.Gateway.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Prehen.Agents.Registry, [profiles: Keyword.get(opts, :agent_profiles, [])]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
