defmodule PrehenWeb.AgentController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Agents.Registry

  def index(conn, _params) do
    agents =
      Registry.all()
      |> Enum.map(fn profile ->
        %{
          agent: profile.name,
          name: profile.name
        }
      end)
      |> Enum.sort_by(& &1.agent)

    json(conn, %{agents: agents})
  end
end
