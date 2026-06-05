import Config

config :mastercard_simulator,
  port: 4001,
  merchant_id: "TEST_MERCHANT",
  api_username: "merchant.TEST_MERCHANT",
  api_password: "test_password_123",
  api_version: "77"

config :logger, :console,
  format: "[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
