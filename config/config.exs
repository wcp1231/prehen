import Config

config :prehen, PrehenWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: PrehenWeb.ErrorJSON], layout: false],
  pubsub_server: Prehen.PubSub,
  server: true

config :prehen, :phoenix_pubsub, name: Prehen.PubSub

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
