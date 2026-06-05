import Config

# Override port via PORT env var at runtime if desired:
#   PORT=4002 mix run --no-halt
config :mastercard_simulator, port: String.to_integer(System.get_env("PORT") || "4444")
