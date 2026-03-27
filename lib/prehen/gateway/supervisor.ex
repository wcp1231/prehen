defmodule Prehen.Gateway.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Prehen.Agents.Registry, [profiles: Keyword.get(opts, :agent_profiles, [])]},
      {Prehen.Gateway.SessionRegistry, []},
      {Prehen.Gateway.InboxProjection, []},
      {DynamicSupervisor, strategy: :one_for_one, name: Prehen.Gateway.SessionWorkerSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
