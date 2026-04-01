defmodule PrehenWeb.AgentController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Agents.Profile
  alias Prehen.Agents.Registry

  def index(conn, _params) do
    profiles = Registry.all()
    default_agent = profiles |> List.first() |> then(&if &1, do: &1.name, else: nil)

    agents =
      profiles
      |> Enum.map(fn profile ->
        %{
          agent: profile.name,
          name: Profile.display_name(profile),
          default: profile.name == default_agent
        }
        |> maybe_put_description(Profile.description(profile))
      end)
      |> Enum.sort_by(& &1.agent)

    json(conn, %{agents: agents})
  end

  defp maybe_put_description(agent, nil), do: agent
  defp maybe_put_description(agent, description), do: Map.put(agent, :description, description)
end
