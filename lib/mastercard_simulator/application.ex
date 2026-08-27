defmodule MastercardSimulator.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:mastercard_simulator, :port, 4001)

    children = [
      MastercardSimulator.TransactionStore,
      MastercardSimulator.ThreeDSStore,
      {Bandit, plug: MastercardSimulator.Router, port: port, scheme: :http}
    ]

    Logger.info("""
    ============================================================
    Mastercard Gateway Simulator starting on http://0.0.0.0:#{port}
    API Base: http://localhost:#{port}/api/rest/version/77
    Health:   http://localhost:#{port}/health
    Admin:    http://localhost:#{port}/admin/transactions
    Credentials: #{Application.get_env(:mastercard_simulator, :api_username, "merchant.TEST_MERCHANT")} / ***
    ============================================================
    """)

    opts = [strategy: :one_for_one, name: MastercardSimulator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
