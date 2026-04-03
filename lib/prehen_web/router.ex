defmodule PrehenWeb.Router do
  use Phoenix.Router

  import Phoenix.Controller

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", PrehenWeb do
    pipe_through(:browser)

    get("/inbox", InboxPageController, :show)
  end

  scope "/", PrehenWeb do
    pipe_through(:api)

    post("/mcp", MCPController, :handle)
    get("/inbox/sessions", InboxController, :index)
    post("/inbox/sessions", InboxController, :create)
    get("/inbox/sessions/:id", InboxController, :show)
    get("/inbox/sessions/:id/history", InboxController, :history)
    delete("/inbox/sessions/:id", InboxController, :delete)

    resources("/sessions", SessionController, only: [:create, :show, :delete])
    post("/sessions/:id/messages", SessionController, :create_message)
    get("/agents", AgentController, :index)
  end
end
