import Config

test_port = String.to_integer(System.get_env("PORT") || "4000")

config :prehen, PrehenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: test_port],
  check_origin: false,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-endpoint-hmac"

config :logger, level: :info
