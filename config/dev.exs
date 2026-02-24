import Config

config :prehen, PrehenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-endpoint-hmac",
  watchers: []

config :logger, :console, format: "[$level] $message\n"
