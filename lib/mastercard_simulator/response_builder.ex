defmodule MastercardSimulator.ResponseBuilder do
  @moduledoc """
  Builds MPGS-compliant JSON response maps for all supported operations.
  All timestamps are UTC ISO-8601. Amount values are returned as floats.
  """

  # ── Public builders ──────────────────────────────────────────────────────────

  @doc "Successful authorisation / pay / capture / verify response."
  def approved(params) do
    %{
      order_id: order_id,
      transaction_id: transaction_id,
      merchant_id: merchant_id,
      amount: amount,
      currency: currency,
      operation: operation,
      pan: pan,
      scheme: scheme,
      expiry_month: expiry_month,
      expiry_year: expiry_year,
      emv_request: emv_request,
      pos_terminal: pos_terminal
    } = params

    now               = DateTime.utc_now()
    auth_code         = random_padded(6, 999_999)
    stan              = random_padded(5, 99_999)
    txn_identifier    = random_padded(9, 999_999_999)
    batch             = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "") |> String.to_integer()
    settlement_date   = Date.utc_today() |> Date.to_iso8601()
    amt               = parse_amount(amount)

    %{
      "apiOperation"     => operation,
      "gatewayEntryPoint" => "WEB_SERVICES_API",
      "merchant"         => merchant_id,
      "order" => %{
        "amount"                 => amt,
        "authenticationStatus"   => "AUTHENTICATION_NOT_IN_EFFECT",
        "chargeback"             => %{"amount" => 0, "currency" => currency},
        "creationTime"           => DateTime.to_iso8601(now),
        "currency"               => currency,
        "id"                     => order_id,
        "lastUpdatedTime"        => DateTime.to_iso8601(now),
        "merchantAmount"         => amt,
        "merchantCategoryCode"   => "5999",
        "merchantCurrency"       => currency,
        "status"                 => order_status(operation),
        "totalAuthorizedAmount"  => amt,
        "totalCapturedAmount"    => captured_amount(operation, amt),
        "totalDisbursedAmount"   => 0,
        "totalRefundedAmount"    => 0
      },
      "posTerminal"      => echo_pos_terminal(pos_terminal),
      "response" => %{
        "acquirerCode"           => "00",
        "acquirerMessage"        => "Approved",
        "gatewayCode"            => "APPROVED",
        "gatewayRecommendation"  => "NO_ACTION"
      },
      "result" => "SUCCESS",
      "sourceOfFunds" => %{
        "provided" => %{
          "card" => %{
            "brand"            => scheme,
            "emvRequest"       => emv_request || %{},
            "emvResponse"      => sample_emv_response(),
            "expiry"           => %{"month" => expiry_month || "12", "year" => expiry_year || "27"},
            "fundingMethod"    => "DEBIT",
            "number"           => mask_pan(pan),
            "scheme"           => scheme,
            "storedOnFile"     => "NOT_STORED",
            "trackDataProvided" => true
          }
        },
        "type" => "CARD"
      },
      "timeOfLastUpdate" => DateTime.to_iso8601(now),
      "timeOfRecord"     => DateTime.to_iso8601(now),
      "transaction" => %{
        "acquirer" => %{
          "batch"          => batch,
          "date"           => Calendar.strftime(now, "%m%d"),
          "id"             => "SIMULATOR_ACQ",
          "merchantId"     => "9999",
          "settlementDate" => settlement_date,
          "timeZone"       => "+0000",
          "transactionId"  => txn_identifier
        },
        "amount"               => amt,
        "authenticationStatus" => "AUTHENTICATION_NOT_IN_EFFECT",
        "authorizationCode"    => auth_code,
        "currency"             => currency,
        "id"                   => transaction_id,
        "receipt"              => "SIM#{stan}",
        "source"               => "CARD_PRESENT",
        "stan"                 => stan,
        "terminal"             => "SIM001",
        "type"                 => transaction_type(operation)
      },
      "version" => "77"
    }
  end

  @doc "Declined response with scheme response code and message."
  def declined(params, response_code, response_message) do
    %{
      order_id: order_id,
      transaction_id: transaction_id,
      merchant_id: merchant_id,
      amount: amount,
      currency: currency,
      operation: operation
    } = params

    now = DateTime.utc_now()

    %{
      "apiOperation"     => operation,
      "gatewayEntryPoint" => "WEB_SERVICES_API",
      "merchant"         => merchant_id,
      "order" => %{
        "amount"                => parse_amount(amount),
        "currency"              => currency,
        "id"                    => order_id,
        "status"                => "FAILED",
        "totalAuthorizedAmount" => 0,
        "totalCapturedAmount"   => 0,
        "totalRefundedAmount"   => 0
      },
      "response" => %{
        "acquirerCode"          => response_code,
        "acquirerMessage"       => response_message,
        "gatewayCode"           => "DECLINED",
        "gatewayRecommendation" => "DO_NOT_RETRY"
      },
      "result" => "FAILURE",
      "timeOfLastUpdate" => DateTime.to_iso8601(now),
      "timeOfRecord"     => DateTime.to_iso8601(now),
      "transaction" => %{
        "amount"   => parse_amount(amount),
        "currency" => currency,
        "id"       => transaction_id,
        "source"   => "CARD_PRESENT",
        "type"     => transaction_type(operation)
      },
      "version" => "77"
    }
  end

  @doc "Response indicating PIN entry is required (single-tap second-step flow)."
  def pin_required(params) do
    %{order_id: order_id, transaction_id: transaction_id} = params
    now = DateTime.utc_now()

    %{
      "gatewayEntryPoint" => "WEB_SERVICES_API",
      "order" => %{
        "id"     => order_id,
        "status" => "AUTHENTICATION_INITIATED"
      },
      "response" => %{
        "gatewayCode"           => "DECLINED_PIN_REQUIRED",
        "gatewayRecommendation" => "RESUBMIT_WITH_PIN"
      },
      "result"           => "PENDING",
      "timeOfLastUpdate" => DateTime.to_iso8601(now),
      "timeOfRecord"     => DateTime.to_iso8601(now),
      "transaction" => %{
        "id"     => transaction_id,
        "source" => "CARD_PRESENT"
      },
      "version" => "77"
    }
  end

  @doc "Successful void response."
  def void_success(params) do
    %{
      order_id: order_id,
      transaction_id: transaction_id,
      merchant_id: merchant_id,
      amount: amount,
      currency: currency
    } = params

    now = DateTime.utc_now()

    %{
      "apiOperation"     => "VOID",
      "gatewayEntryPoint" => "WEB_SERVICES_API",
      "merchant"         => merchant_id,
      "order" => %{
        "amount"   => parse_amount(amount),
        "currency" => currency,
        "id"       => order_id,
        "status"   => "VOIDED"
      },
      "response" => %{
        "acquirerCode"          => "00",
        "acquirerMessage"       => "Approved",
        "gatewayCode"           => "APPROVED",
        "gatewayRecommendation" => "NO_ACTION"
      },
      "result"           => "SUCCESS",
      "timeOfLastUpdate" => DateTime.to_iso8601(now),
      "timeOfRecord"     => DateTime.to_iso8601(now),
      "transaction" => %{
        "id"     => transaction_id,
        "source" => "CARD_PRESENT",
        "type"   => "VOID"
      },
      "version" => "77"
    }
  end

  @doc "Successful refund response."
  def refund_success(params) do
    %{
      order_id: order_id,
      transaction_id: transaction_id,
      merchant_id: merchant_id,
      amount: amount,
      currency: currency
    } = params

    now       = DateTime.utc_now()
    auth_code = random_padded(6, 999_999)

    %{
      "apiOperation"     => "REFUND",
      "gatewayEntryPoint" => "WEB_SERVICES_API",
      "merchant"         => merchant_id,
      "order" => %{
        "amount"              => parse_amount(amount),
        "currency"            => currency,
        "id"                  => order_id,
        "status"              => "REFUNDED",
        "totalRefundedAmount" => parse_amount(amount)
      },
      "response" => %{
        "acquirerCode"          => "00",
        "acquirerMessage"       => "Approved",
        "gatewayCode"           => "APPROVED",
        "gatewayRecommendation" => "NO_ACTION"
      },
      "result"           => "SUCCESS",
      "timeOfLastUpdate" => DateTime.to_iso8601(now),
      "timeOfRecord"     => DateTime.to_iso8601(now),
      "transaction" => %{
        "amount"            => parse_amount(amount),
        "authorizationCode" => auth_code,
        "currency"          => currency,
        "id"                => transaction_id,
        "source"            => "CARD_PRESENT",
        "type"              => "REFUND"
      },
      "version" => "77"
    }
  end

  @doc "404 / transaction-not-found error response."
  def not_found(order_id, transaction_id) do
    %{
      "error" => %{
        "cause"          => "INVALID_REQUEST",
        "explanation"    => "Transaction not found",
        "field"          => "transaction.id",
        "validationType" => "INVALID"
      },
      "order"       => %{"id" => order_id},
      "result"      => "ERROR",
      "transaction" => %{"id" => transaction_id},
      "version"     => "77"
    }
  end

  @doc "401 auth-error response body."
  def auth_error do
    %{
      "error" => %{
        "cause"       => "INVALID_CREDENTIALS",
        "explanation" => "Invalid API credentials"
      },
      "result"  => "ERROR",
      "version" => "77"
    }
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp parse_amount(n) when is_float(n),   do: n
  defp parse_amount(n) when is_integer(n), do: n * 1.0

  defp parse_amount(s) when is_binary(s) do
    case Float.parse(s) do
      {v, _} -> v
      :error ->
        case Integer.parse(s) do
          {v, _} -> v * 1.0
          :error  -> 0.0
        end
    end
  end

  defp parse_amount(_), do: 0.0

  defp mask_pan(nil), do: "xxxxxxxxxxxx0000"

  defp mask_pan(pan) do
    clean = String.replace(pan, ~r/[^0-9x]/, "")
    len   = String.length(clean)

    if len >= 10 do
      first6 = String.slice(clean, 0, 6)
      last4  = String.slice(clean, -4, 4)
      "#{first6}xxxxxx#{last4}"
    else
      "xxxxxxxxxxxx#{String.slice(clean, -4, 4)}"
    end
  end

  defp order_status("AUTHORIZE"), do: "AUTHORIZED"
  defp order_status("PAY"),       do: "CAPTURED"
  defp order_status("CAPTURE"),   do: "CAPTURED"
  defp order_status("VERIFY"),    do: "VERIFIED"
  defp order_status(_),           do: "CAPTURED"

  defp captured_amount("AUTHORIZE", _amt), do: 0
  defp captured_amount("VERIFY", _amt),    do: 0
  defp captured_amount(_op, amt),          do: amt

  defp transaction_type("AUTHORIZE"), do: "AUTHORIZATION"
  defp transaction_type("PAY"),       do: "PAYMENT"
  defp transaction_type("CAPTURE"),   do: "CAPTURE"
  defp transaction_type("REFUND"),    do: "REFUND"
  defp transaction_type("VOID"),      do: "VOID"
  defp transaction_type("VERIFY"),    do: "VERIFICATION"
  defp transaction_type(_),           do: "PAYMENT"

  defp sample_emv_response do
    %{
      "72" => "9F180408041215860E04DA9F5809030691D72E6F027DC6",
      "91" => "B7D5309D4B3E6CDB3030"
    }
  end

  defp echo_pos_terminal(nil), do: %{}

  defp echo_pos_terminal(pos) do
    %{
      "attended"              => Map.get(pos, "attended", "ATTENDED"),
      "cardPresenceCapability" => Map.get(pos, "cardPresenceCapability", "CARD_PRESENT"),
      "cardholderActivated"   => Map.get(pos, "cardholderActivated", "NOT_CARDHOLDER_ACTIVATED"),
      "inputCapability"       => Map.get(pos, "inputCapability", "CONTACTLESS_CHIP"),
      "location"              => Map.get(pos, "location", "MERCHANT_TERMINAL_ON_PREMISES"),
      "panEntryMode"          => Map.get(pos, "panEntryMode", "CONTACTLESS")
    }
  end

  defp random_padded(length, max) do
    :rand.uniform(max)
    |> Integer.to_string()
    |> String.pad_leading(length, "0")
  end
end
