defmodule PrehenWeb.AgentController do
  use Phoenix.Controller, formats: [:json]

  alias Prehen.Config.Structured
  alias Prehen.Workspace.Paths

  def index(conn, _params) do
    workspace_dir = Paths.default_workspace_dir()
    global_dir = Paths.default_global_dir()
    loaded = Structured.load(workspace_dir, global_dir)

    agents =
      loaded.agents
      |> Enum.map(fn {key, config} ->
        %{
          agent: key,
          name: config["name"] || key,
          description: config["description"]
        }
      end)
      |> Enum.sort_by(& &1.agent)

    json(conn, %{agents: agents})
  end
end
