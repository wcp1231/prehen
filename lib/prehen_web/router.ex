defmodule PrehenWeb.Router do
  use Phoenix.Router

  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", PrehenWeb do
    pipe_through :api

    resources "/sessions", SessionController, only: [:create, :index, :show, :delete]
    get "/sessions/:id/replay", SessionController, :replay

    get "/agents", AgentController, :index
  end
end
