defmodule MastercardSimulator.TransactionHandler do
  @moduledoc """
  Dispatches each MPGS API operation to the correct handler and persists
  the result in the TransactionStore.

  Supported operations: PAY, AUTHORIZE, CAPTURE, VOID, REFUND, VERIFY
  """

  require Logger
  alias MastercardSimulator.{TransactionStore, ScenarioEngine, ResponseBuilder}

  # ── Entry points ─────────────────────────────────────────────────────────────

  @doc "Handle a PUT (create/update) transaction request."
  def handle(merchant_id, order_id, transaction_id, body) do
    operation = Map.get(body, "apiOperation", "PAY")

    Logger.info(
      "[MPGS Simulator] OP=#{operation} | merchant=#{merchant_id} | " <>
      "order=#{order_id} | txn=#{transaction_id}"
    )

    case operation do
      op when op in ["PAY", "AUTHORIZE"] ->
        handle_pay_or_auth(merchant_id, order_id, transaction_id, body, op)

      "CAPTURE" ->
        handle_capture(merchant_id, order_id, transaction_id, body)

      "VOID" ->
        handle_void(merchant_id, order_id, transaction_id, body)

      "REFUND" ->
        handle_refund(merchant_id, order_id, transaction_id, body)

      "VERIFY" ->
        handle_verify(merchant_id, order_id, transaction_id, body)

      unknown ->
        error = %{
          "error" => %{
            "cause"       => "INVALID_REQUEST",
            "explanation" => "Unsupported apiOperation: #{unknown}"
          },
          "result"  => "ERROR",
          "version" => "77"
        }
        {:error, 400, error}
    end
  end

  @doc "Handle a GET (query) transaction request."
  def handle_get(_merchant_id, order_id, transaction_id) do
    case TransactionStore.get(order_id, transaction_id) do
      {:ok, record}         -> {:ok, 200, record.response}
      {:error, :not_found}  -> {:ok, 404, ResponseBuilder.not_found(order_id, transaction_id)}
    end
  end

  # ── Operation handlers ───────────────────────────────────────────────────────

  defp handle_pay_or_auth(merchant_id, order_id, transaction_id, body, operation) do
    card          = get_in(body, ["sourceOfFunds", "provided", "card"]) || %{}
    track2        = Map.get(card, "track2", "")
    pan           = extract_pan(card, track2)
    expiry        = Map.get(card, "expiry", %{})
    emv_request   = Map.get(card, "emvRequest", %{})
    pos_terminal  = Map.get(body, "posTerminal", %{})
    order         = Map.get(body, "order", %{})
    amount        = Map.get(order, "amount", 0)
    currency      = Map.get(order, "currency", "USD")
    scheme        = ScenarioEngine.detect_scheme(pan)
    single_tap    = get_in(body, ["posTerminal", "singleTapIndicator"])

    # A second PIN-submission request carries targetTransactionId or a pin payload
    is_pin_resubmission =
      get_in(body, ["transaction", "targetTransactionId"]) != nil or
      get_in(body, ["sourceOfFunds", "provided", "card", "pin", "payload"]) != nil

    params = %{
      merchant_id:   merchant_id,
      order_id:      order_id,
      transaction_id: transaction_id,
      amount:        amount,
      currency:      currency,
      operation:     operation,
      pan:           pan,
      scheme:        scheme,
      expiry_month:  Map.get(expiry, "month"),
      expiry_year:   Map.get(expiry, "year"),
      emv_request:   emv_request,
      pos_terminal:  pos_terminal
    }

    outcome =
      if is_pin_resubmission do
        # Second tap with PIN always approves in simulator
        {:approved, "00", "Approved"}
      else
        ScenarioEngine.determine_outcome(pan, amount, currency)
      end

    case outcome do
      {:approved, _code, _msg} ->
        response = ResponseBuilder.approved(params)
        store(order_id, transaction_id, params, response, "APPROVED")
        {:ok, 200, response}

      {:pin_required, _code, _msg} ->
        if single_tap in ["true", true] do
          response = ResponseBuilder.pin_required(params)
          store(order_id, transaction_id, params, response, "PIN_REQUIRED")
          {:ok, 200, response}
        else
          # Terminal doesn't support single-tap PIN — decline outright
          response = ResponseBuilder.declined(params, "55", "Incorrect PIN")
          store(order_id, transaction_id, params, response, "DECLINED")
          {:ok, 200, response}
        end

      {:declined, code, msg} ->
        response = ResponseBuilder.declined(params, code, msg)
        store(order_id, transaction_id, params, response, "DECLINED")
        {:ok, 200, response}
    end
  end

  defp handle_capture(merchant_id, order_id, transaction_id, body) do
    # Look up the original authorisation for this order
    auth_record =
      TransactionStore.get_by_order(order_id)
      |> Enum.find(&(&1.status == "APPROVED"))

    case auth_record do
      nil ->
        {:ok, 422, %{
          "error" => %{
            "cause"       => "INVALID_REQUEST",
            "explanation" => "No approved authorisation found for order: #{order_id}"
          },
          "result"  => "ERROR",
          "version" => "77"
        }}

      orig ->
        order    = Map.get(body, "order", %{})
        amount   = Map.get(order, "amount") || get_in(orig, [:params, :amount]) || 0
        currency = Map.get(order, "currency") || get_in(orig, [:params, :currency]) || "USD"

        params = %{
          merchant_id:    merchant_id,
          order_id:       order_id,
          transaction_id: transaction_id,
          amount:         amount,
          currency:       currency,
          operation:      "CAPTURE",
          pan:            get_in(orig, [:params, :pan]),
          scheme:         get_in(orig, [:params, :scheme]),
          expiry_month:   get_in(orig, [:params, :expiry_month]),
          expiry_year:    get_in(orig, [:params, :expiry_year]),
          emv_request:    %{},
          pos_terminal:   %{}
        }

        response = ResponseBuilder.approved(params)
        store(order_id, transaction_id, params, response, "CAPTURED")
        {:ok, 200, response}
    end
  end

  defp handle_void(merchant_id, order_id, transaction_id, body) do
    order    = Map.get(body, "order", %{})
    amount   = Map.get(order, "amount", 0)
    currency = Map.get(order, "currency", "USD")

    params = %{
      merchant_id:    merchant_id,
      order_id:       order_id,
      transaction_id: transaction_id,
      amount:         amount,
      currency:       currency
    }

    response = ResponseBuilder.void_success(params)
    store(order_id, transaction_id, params, response, "VOIDED")
    {:ok, 200, response}
  end

  defp handle_refund(merchant_id, order_id, transaction_id, body) do
    order    = Map.get(body, "order", %{})
    amount   = Map.get(order, "amount", 0)
    currency = Map.get(order, "currency", "USD")

    params = %{
      merchant_id:    merchant_id,
      order_id:       order_id,
      transaction_id: transaction_id,
      amount:         amount,
      currency:       currency
    }

    response = ResponseBuilder.refund_success(params)
    store(order_id, transaction_id, params, response, "REFUNDED")
    {:ok, 200, response}
  end

  defp handle_verify(merchant_id, order_id, transaction_id, body) do
    card         = get_in(body, ["sourceOfFunds", "provided", "card"]) || %{}
    track2       = Map.get(card, "track2", "")
    pan          = extract_pan(card, track2)
    expiry       = Map.get(card, "expiry", %{})
    pos_terminal = Map.get(body, "posTerminal", %{})
    order        = Map.get(body, "order", %{})
    currency     = Map.get(order, "currency", "USD")
    scheme       = ScenarioEngine.detect_scheme(pan)

    params = %{
      merchant_id:    merchant_id,
      order_id:       order_id,
      transaction_id: transaction_id,
      amount:         0,
      currency:       currency,
      operation:      "VERIFY",
      pan:            pan,
      scheme:         scheme,
      expiry_month:   Map.get(expiry, "month"),
      expiry_year:    Map.get(expiry, "year"),
      emv_request:    Map.get(card, "emvRequest", %{}),
      pos_terminal:   pos_terminal
    }

    response = ResponseBuilder.approved(params)
    store(order_id, transaction_id, params, response, "VERIFIED")
    {:ok, 200, response}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp store(order_id, transaction_id, params, response, status) do
    TransactionStore.put(order_id, transaction_id, %{
      order_id:       order_id,
      transaction_id: transaction_id,
      params:         params,
      response:       response,
      status:         status,
      stored_at:      DateTime.utc_now()
    })
  end

  # Extract PAN from track2 data (format: PAN=expiry...) or card.number field
  defp extract_pan(card, track2) do
    cond do
      is_binary(track2) and track2 != "" and String.contains?(track2, "=") ->
        track2
        |> String.split("=")
        |> List.first()
        |> String.replace(~r/[^0-9x]/, "")

      is_binary(Map.get(card, "number")) ->
        card
        |> Map.get("number")
        |> String.replace(~r/[^0-9x]/, "")

      true ->
        ""
    end
  end
end
