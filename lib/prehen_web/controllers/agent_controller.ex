defmodule PrehenWeb.AgentController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Agents.Registry

  def index(conn, _params) do
    profiles = Registry.all()
    default_agent = profiles |> List.first() |> then(&if &1, do: &1.name, else: nil)

    agents =
      profiles
      |> Enum.map(fn profile ->
        %{
          agent: profile.name,
          name: profile.name,
          default: profile.name == default_agent
        }
      end)
      |> Enum.sort_by(& &1.agent)

    json(conn, %{agents: agents})
  end
end
