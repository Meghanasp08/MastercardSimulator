import Config

# Use a high port number for tests to avoid conflicts
config :mastercard_simulator,
  port: 4099,
  api_username: "merchant.TEST_MERCHANT",
  api_password: "test_password_123"
