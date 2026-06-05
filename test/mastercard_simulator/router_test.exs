defmodule MastercardSimulator.RouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias MastercardSimulator.{Router, TransactionStore}

  @opts Router.init([])

  # Basic Auth header for all authenticated requests
  @auth "Basic " <> Base.encode64("merchant.TEST_MERCHANT:test_password_123")

  setup do
    TransactionStore.clear()
    :ok
  end

  # ── Health ───────────────────────────────────────────────────────────────────

  test "GET /health returns 200 without auth" do
    conn = conn(:get, "/health") |> Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "UP"
  end

  # ── Auth guard ───────────────────────────────────────────────────────────────

  test "PUT transaction without auth returns 401" do
    conn =
      conn(:put, "/api/rest/version/77/merchant/M1/order/O1/transaction/T1", Jason.encode!(%{
        "apiOperation" => "PAY",
        "order" => %{"amount" => "10.00", "currency" => "USD"},
        "sourceOfFunds" => %{
          "provided" => %{"card" => %{"number" => "5123450000000000", "track2" => "5123450000000000=2712"}},
          "type" => "CARD"
        }
      }))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 401
  end

  # ── PAY – Approved ───────────────────────────────────────────────────────────

  test "PAY with Mastercard test card returns APPROVED" do
    conn = authenticated_pay("5123450000000000", "20.50", "USD", "PAY")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == "SUCCESS"
    assert body["response"]["gatewayCode"] == "APPROVED"
    assert body["sourceOfFunds"]["provided"]["card"]["scheme"] == "MASTERCARD"
  end

  test "PAY with Visa test card returns APPROVED" do
    conn = authenticated_pay("4111111111111111", "15.25", "USD", "PAY")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == "SUCCESS"
    assert body["sourceOfFunds"]["provided"]["card"]["scheme"] == "VISA"
  end

  # ── Declined scenarios ───────────────────────────────────────────────────────

  test "PAY with declined test card returns FAILURE" do
    conn = authenticated_pay("5999990000000000", "10.00", "USD", "PAY")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == "FAILURE"
    assert body["response"]["gatewayCode"] == "DECLINED"
    assert body["response"]["acquirerCode"] == "05"
  end

  test "PAY with insufficient-funds card returns 51" do
    conn = authenticated_pay("5777770000000000", "10.00", "USD", "PAY")
    body = Jason.decode!(conn.resp_body)
    assert body["response"]["acquirerCode"] == "51"
  end

  test "PAY with expired card returns 54" do
    conn = authenticated_pay("5666660000000000", "10.00", "USD", "PAY")
    body = Jason.decode!(conn.resp_body)
    assert body["response"]["acquirerCode"] == "54"
  end

  test "PAY with amount above limit returns 61" do
    conn = authenticated_pay("5123450000000000", "100000", "USD", "PAY")
    body = Jason.decode!(conn.resp_body)
    assert body["response"]["acquirerCode"] == "61"
  end

  # ── PIN Required flow ────────────────────────────────────────────────────────

  test "PAY with PIN-required card and singleTapIndicator returns DECLINED_PIN_REQUIRED" do
    body = pay_body("5888880000000000", "30.00", "USD", "PAY")
    body = put_in(body, ["posTerminal", "singleTapIndicator"], "true")

    conn =
      conn(:put, "/api/rest/version/77/merchant/M1/order/O-pin/transaction/T1", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    resp = Jason.decode!(conn.resp_body)
    assert resp["response"]["gatewayCode"] == "DECLINED_PIN_REQUIRED"
    assert resp["result"] == "PENDING"
  end

  test "Second PAY with targetTransactionId (PIN submitted) returns APPROVED" do
    body =
      pay_body("5888880000000000", "30.00", "USD", "PAY")
      |> put_in(["posTerminal", "singleTapIndicator"], "true")
      |> put_in(["transaction"], %{"targetTransactionId" => "T1"})
      |> put_in(["sourceOfFunds", "provided", "card", "pin"], %{
        "payload" => "AABBCCDD",
        "keySerialNumber" => "00000000000000000001"
      })

    conn =
      conn(:put, "/api/rest/version/77/merchant/M1/order/O-pin/transaction/T2", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    resp = Jason.decode!(conn.resp_body)
    assert resp["result"] == "SUCCESS"
    assert resp["response"]["gatewayCode"] == "APPROVED"
  end

  # ── AUTHORIZE + CAPTURE ──────────────────────────────────────────────────────

  test "AUTHORIZE then CAPTURE lifecycle" do
    # Step 1: Authorize
    auth_conn = authenticated_pay("5123450000000000", "50.00", "AUD", "AUTHORIZE", "O-auth-cap", "T1")
    auth_body  = Jason.decode!(auth_conn.resp_body)
    assert auth_body["result"] == "SUCCESS"
    assert auth_body["order"]["status"] == "AUTHORIZED"

    # Step 2: Capture
    cap_body = %{
      "apiOperation" => "CAPTURE",
      "order" => %{"amount" => "50.00", "currency" => "AUD"}
    }

    cap_conn =
      conn(:put, "/api/rest/version/77/merchant/M1/order/O-auth-cap/transaction/T2", Jason.encode!(cap_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    cap_resp = Jason.decode!(cap_conn.resp_body)
    assert cap_resp["result"] == "SUCCESS"
    assert cap_resp["order"]["status"] == "CAPTURED"
  end

  # ── VOID ─────────────────────────────────────────────────────────────────────

  test "VOID returns SUCCESS" do
    body = %{"apiOperation" => "VOID", "order" => %{"amount" => "15.25", "currency" => "USD"}}

    conn =
      conn(:put, "/api/rest/version/77/merchant/M1/order/O-void/transaction/T1", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    resp = Jason.decode!(conn.resp_body)
    assert resp["result"] == "SUCCESS"
    assert resp["order"]["status"] == "VOIDED"
  end

  # ── REFUND ───────────────────────────────────────────────────────────────────

  test "REFUND returns SUCCESS" do
    body = %{"apiOperation" => "REFUND", "order" => %{"amount" => "25.75", "currency" => "USD"}}

    conn =
      conn(:put, "/api/rest/version/77/merchant/M1/order/O-refund/transaction/T1", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    resp = Jason.decode!(conn.resp_body)
    assert resp["result"] == "SUCCESS"
    assert resp["order"]["status"] == "REFUNDED"
  end

  # ── GET transaction ───────────────────────────────────────────────────────────

  test "GET existing transaction returns stored response" do
    authenticated_pay("5123450000000000", "10.00", "USD", "PAY", "O-get", "T-get")

    conn =
      conn(:get, "/api/rest/version/77/merchant/M1/order/O-get/transaction/T-get")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == "SUCCESS"
  end

  test "GET non-existent transaction returns 404" do
    conn =
      conn(:get, "/api/rest/version/77/merchant/M1/order/NO-ORDER/transaction/NO-TXN")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == "ERROR"
  end

  # ── Admin ─────────────────────────────────────────────────────────────────────

  test "GET /admin/transactions returns all transactions" do
    authenticated_pay("5123450000000000", "5.00", "USD", "PAY", "O-admin", "T-admin")

    conn =
      conn(:get, "/admin/transactions")
      |> put_req_header("authorization", @auth)
      |> Router.call(@opts)

    body = Jason.decode!(conn.resp_body)
    assert body["count"] >= 1
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp authenticated_pay(pan, amount, currency, operation, order_id \\ "ORDER-1", txn_id \\ "TXN-1") do
    conn(:put,
      "/api/rest/version/77/merchant/M1/order/#{order_id}/transaction/#{txn_id}",
      Jason.encode!(pay_body(pan, amount, currency, operation))
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", @auth)
    |> Router.call(@opts)
  end

  defp pay_body(pan, amount, currency, operation) do
    %{
      "apiOperation" => operation,
      "order" => %{"amount" => amount, "currency" => currency},
      "posTerminal" => %{
        "attended"              => "ATTENDED",
        "cardPresenceCapability" => "CARD_PRESENT",
        "cardholderActivated"   => "MPOS_ACCEPTANCE_DEVICE",
        "inputCapability"       => "CONTACTLESS_CHIP",
        "lane"                  => "SIM001",
        "location"              => "MERCHANT_TERMINAL_ON_PREMISES",
        "panEntryMode"          => "CONTACTLESS",
        "pinEntryCapability"    => "PIN_SUPPORTED"
      },
      "sourceOfFunds" => %{
        "provided" => %{
          "card" => %{
            "number" => pan,
            "track2" => "#{pan}=2712",
            "expiry" => %{"month" => "12", "year" => "27"},
            "emvRequest" => %{
              "5F2A" => "840",
              "82"   => "5C00",
              "84"   => "A0000000031010",
              "95"   => "0000000000",
              "9A"   => "260604",
              "9C"   => "00",
              "9F02" => "000000001025",
              "9F10" => "06020103A02000",
              "9F1A" => "840",
              "9F26" => "51B579DE8D55E180",
              "9F27" => "80",
              "9F34" => "000000",
              "9F36" => "0201",
              "9F37" => "6388675D",
              "9F6E" => "00560000313400"
            }
          }
        },
        "type" => "CARD"
      },
      "transaction" => %{"source" => "CARD_PRESENT"}
    }
  end
end
