defmodule MastercardSimulator.Router do
  @moduledoc """
  Plug router that exposes the Mastercard Gateway REST API surface.

  Authenticated routes (HTTP Basic Auth required):
    PUT  /api/rest/version/:v/merchant/:mid/order/:oid/transaction/:tid
    GET  /api/rest/version/:v/merchant/:mid/order/:oid/transaction/:tid
    GET  /api/rest/version/:v/merchant/:mid/order/:oid
    GET  /admin/transactions

  Public routes (no auth):
    GET  /health
  """

  use Plug.Router
  require Logger

  alias MastercardSimulator.{AuthPlug, TransactionHandler, TransactionStore}

  # ── Plug pipeline ─────────────────────────────────────────────────────────────
  # Order matters:
  #   1. :match   – identify the route
  #   2. Logger   – log the request
  #   3. Parsers  – decode JSON body
  #   4. AuthPlug – verify credentials (skips /health)
  #   5. :dispatch – run the route handler

  plug :match

  plug Plug.Logger, log: :info

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json", "application/*", "*/*"],
    json_decoder: Jason

  plug AuthPlug

  plug :dispatch

  # ── Public route ─────────────────────────────────────────────────────────────

  get "/health" do
    send_json(conn, 200, %{
      status:  "UP",
      service: "Mastercard Gateway Simulator",
      version: "77",
      time:    DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  # ── MPGS Transaction API ──────────────────────────────────────────────────────

  # PUT  /api/rest/version/:api_version/merchant/:merchant_id/order/:order_id/transaction/:transaction_id
  put "/api/rest/version/:_api_version/merchant/:merchant_id/order/:order_id/transaction/:transaction_id" do
    body = conn.body_params || %{}

    case TransactionHandler.handle(merchant_id, order_id, transaction_id, body) do
      {:ok, status, response}    -> send_json(conn, status, response)
      {:error, status, response} -> send_json(conn, status, response)
    end
  end

  # GET  /api/rest/version/:api_version/merchant/:merchant_id/order/:order_id/transaction/:transaction_id
  get "/api/rest/version/:_api_version/merchant/:merchant_id/order/:order_id/transaction/:transaction_id" do
    case TransactionHandler.handle_get(merchant_id, order_id, transaction_id) do
      {:ok, status, response} -> send_json(conn, status, response)
    end
  end

  # GET  /api/rest/version/:api_version/merchant/:merchant_id/order/:order_id
  get "/api/rest/version/:_api_version/merchant/:merchant_id/order/:order_id" do
    txns = TransactionStore.get_by_order(order_id)
    responses = Enum.map(txns, & &1.response)

    send_json(conn, 200, %{
      "merchant"    => merchant_id,
      "order"       => %{"id" => order_id},
      "transaction" => responses,
      "result"      => "SUCCESS",
      "version"     => "77"
    })
  end

  # POST  /api/rest/version/:api_version/merchant/:merchant_id/session
  post "/api/rest/version/:_api_version/merchant/:merchant_id/session" do
    # Generate a unique session ID
    session_id = "SESSION_" <> (:crypto.strong_rand_bytes(8) |> Base.encode64() |> String.replace(["+", "/"], ""))
    
    Logger.info("Session creation request from merchant: #{merchant_id}")
    
    # Return successful session creation response
    send_json(conn, 201, %{
      "session" => %{
        "id" => session_id,
        "created" => DateTime.to_iso8601(DateTime.utc_now()),
        "updated" => DateTime.to_iso8601(DateTime.utc_now()),
        "validityPeriod" => 3600,
        "merchant" => merchant_id
      },
      "result" => "SUCCESS",
      "version" => "77"
    })
  end

  # ── Admin endpoint ────────────────────────────────────────────────────────────

  # GET  /admin/transactions   (useful for debugging / test verification)
  get "/admin/transactions" do
    all = TransactionStore.all()

    summary =
      Enum.map(all, fn t ->
        %{
          order_id:       t.order_id,
          transaction_id: t.transaction_id,
          status:         t.status,
          operation:      get_in(t, [:params, :operation]),
          amount:         get_in(t, [:params, :amount]),
          currency:       get_in(t, [:params, :currency]),
          scheme:         get_in(t, [:params, :scheme]),
          stored_at:      DateTime.to_iso8601(t.stored_at)
        }
      end)

    send_json(conn, 200, %{transactions: summary, count: length(summary)})
  end

  # DELETE /admin/transactions  — wipe all stored transactions (test helper)
  delete "/admin/transactions" do
    TransactionStore.clear()
    send_json(conn, 200, %{result: "OK", message: "All transactions cleared"})
  end

  # ── Catch-all ─────────────────────────────────────────────────────────────────

  match _ do
    send_json(conn, 404, %{
      "error"   => %{"cause" => "NOT_FOUND", "explanation" => "The requested resource was not found"},
      "result"  => "ERROR",
      "version" => "77"
    })
  end

  # ── Helper ───────────────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
