defmodule PrehenWeb.Router do
  use Phoenix.Router

  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PrehenWeb do
    pipe_through :api

    resources "/sessions", SessionController, only: [:create, :show, :delete]
    post "/sessions/:id/messages", SessionController, :create_message
    get "/agents", AgentController, :index
  end
end
