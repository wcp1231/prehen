defmodule PrehenWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :prehen

  socket("/socket", PrehenWeb.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :prehen,
    only: ~w(inbox.js inbox.css)
  )

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(CORSPlug)
  plug(PrehenWeb.Router)
end
