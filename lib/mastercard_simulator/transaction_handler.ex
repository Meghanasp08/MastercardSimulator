defmodule MastercardSimulator.TransactionHandler do
  @moduledoc """
  Dispatches each MPGS API operation to the correct handler and persists
  the result in the TransactionStore.

  Supported operations: PAY, AUTHORIZE, CAPTURE, VOID, REFUND, VERIFY,
  CHECK_3DS_ENROLLMENT (3DS1), INITIATE_AUTHENTICATION / AUTHENTICATE_PAYER
  (3DS2 for the Hosted Session integration — the merchant server drives the
  challenge itself instead of session.js).
  """

  require Logger
  alias MastercardSimulator.{TransactionStore, ScenarioEngine, ResponseBuilder, ThreeDSStore, ThreeDSEngine}

  # ── Entry points ─────────────────────────────────────────────────────────────

  @doc "Handle a PUT (create/update) transaction request."
  def handle(merchant_id, order_id, transaction_id, body, base_url \\ "http://localhost") do
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

      "CHECK_3DS_ENROLLMENT" ->
        handle_check_3ds_enrollment(merchant_id, order_id, transaction_id, body, base_url)

      "INITIATE_AUTHENTICATION" ->
        handle_initiate_authentication(order_id, transaction_id, body)

      "AUTHENTICATE_PAYER" ->
        handle_authenticate_payer(order_id, transaction_id, body, base_url)

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
      pos_terminal:  pos_terminal,
      authentication_status: authentication_status_for(order_id)
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
          pos_terminal:   %{},
          authentication_status: authentication_status_for(order_id)
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

  defp handle_check_3ds_enrollment(merchant_id, order_id, transaction_id, body, base_url) do
    card     = get_in(body, ["sourceOfFunds", "provided", "card"]) || %{}
    pan      = extract_pan(card, Map.get(card, "track2", ""))
    order    = Map.get(body, "order", %{})
    amount   = Map.get(order, "amount", 0)
    currency = Map.get(order, "currency", "USD")

    if ThreeDSEngine.enrolled?(pan) do
      challenge_id = random_id()

      ThreeDSStore.put("challenge:" <> challenge_id, %{
        merchant_id:    merchant_id,
        order_id:       order_id,
        transaction_id: transaction_id,
        amount:         amount,
        currency:       currency,
        status:         :pending
      })

      response = ResponseBuilder.three_ds_enrolled(challenge_id, order_id, transaction_id, amount, currency, base_url)
      {:ok, 200, response}
    else
      {:ok, 200, ResponseBuilder.three_ds_not_enrolled()}
    end
  end

  @doc "Handle POST .../3DSecureId/:id — decode the ACS PaRes and report the outcome."
  def process_acs_result(three_ds_id, body) do
    pa_res = get_in(body, ["3DSecure", "paRes"])
    outcome = ThreeDSEngine.decode_result(pa_res)

    case ThreeDSStore.get("challenge:" <> three_ds_id) do
      {:ok, ctx} -> ThreeDSStore.merge("challenge:" <> three_ds_id, Map.put(ctx, :status, outcome))
      {:error, :not_found} -> :ok
    end

    {:ok, 200, ResponseBuilder.acs_result(outcome)}
  end

  # ── 3DS2 Hosted Session (merchant-server-driven) ─────────────────────────────
  #
  # For the Hosted Session integration session.js only tokenises the card; the
  # merchant server then runs the challenge itself with two calls on the order
  # transaction — INITIATE_AUTHENTICATION then AUTHENTICATE_PAYER — before it
  # calls PAY/AUTHORIZE. State for the flow is kept under "order3ds:<order_id>"
  # (one authentication per order) so the later PAY on the same order can echo
  # the resolved authenticationStatus.

  defp handle_initiate_authentication(order_id, transaction_id, body) do
    session_id = get_in(body, ["session", "id"])
    order      = Map.get(body, "order", %{})
    amount     = Map.get(order, "amount", 0)
    currency   = Map.get(order, "currency", "USD")

    pan      = session_pan(session_id)
    enrolled = is_nil(pan) or ThreeDSEngine.enrolled?(pan)

    ThreeDSStore.put("order3ds:" <> order_id, %{
      stage:          :initiated,
      session_id:     session_id,
      transaction_id: transaction_id,
      amount:         amount,
      currency:       currency,
      pan:            pan,
      enrolled:       enrolled
    })

    {:ok, 200, %{
      "result"      => "SUCCESS",
      "version"     => "77",
      "transaction" => %{"id" => transaction_id},
      "authentication" => %{
        "version"           => "3DS2",
        "transactionStatus" => if(enrolled, do: "C", else: "Y")
      },
      "response" => %{"gatewayRecommendation" => "PROCEED"}
    }}
  end

  defp handle_authenticate_payer(order_id, transaction_id, body, base_url) do
    redirect_response_url = get_in(body, ["authentication", "redirectResponseUrl"])
    session_id            = get_in(body, ["session", "id"])

    ctx =
      case ThreeDSStore.get("order3ds:" <> order_id) do
        {:ok, data} -> data
        {:error, :not_found} -> %{}
      end

    pan      = Map.get(ctx, :pan) || session_pan(session_id)
    enrolled = Map.get(ctx, :enrolled, is_nil(pan) or ThreeDSEngine.enrolled?(pan))

    if enrolled do
      auth_id = "AUTHPAYER_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

      ThreeDSStore.merge("order3ds:" <> order_id, %{
        stage:                 :pending_challenge,
        transaction_id:        transaction_id,
        redirect_response_url: redirect_response_url,
        auth_id:               auth_id
      })

      ThreeDSStore.put("authpayer:" <> auth_id, %{order_id: order_id})

      {:ok, 200, %{
        "result"  => "SUCCESS",
        "version" => "77",
        "authentication" => %{
          "version"      => "3DS2",
          "redirectHtml" => authenticate_payer_redirect_html(auth_id, base_url)
        },
        "response" => %{"gatewayRecommendation" => "PROCEED"}
      }}
    else
      # Frictionless test card — no challenge, merchant server pays immediately.
      ThreeDSStore.merge("order3ds:" <> order_id, %{
        stage:                 :authenticated,
        transaction_id:        transaction_id,
        outcome:               :pass,
        redirect_response_url: redirect_response_url
      })

      {:ok, 200, %{
        "result"  => "SUCCESS",
        "version" => "77",
        "authentication" => %{"version" => "3DS2", "transactionStatus" => "Y"},
        "response" => %{"gatewayRecommendation" => "PROCEED"}
      }}
    end
  end

  @doc """
  Finish an AUTHENTICATE_PAYER challenge: called by the OTP page embedded in
  the `redirectHtml`. Records the outcome against the order and returns the
  merchant `redirectResponseUrl` with the gateway recommendation appended, so
  the caller can navigate the payer's browser back to the merchant.
  """
  def complete_authenticate_payer(auth_id, otp) do
    with {:ok, %{order_id: order_id}} <- ThreeDSStore.get("authpayer:" <> auth_id),
         {:ok, ctx}                   <- ThreeDSStore.get("order3ds:" <> order_id),
         url when is_binary(url) and url != "" <- Map.get(ctx, :redirect_response_url) do
      outcome =
        case ThreeDSEngine.forced_challenge_outcome(Map.get(ctx, :pan)) do
          nil    -> if ThreeDSEngine.valid_otp?(otp), do: :pass, else: :fail
          forced -> forced
        end

      ThreeDSStore.merge("order3ds:" <> order_id, %{stage: :authenticated, outcome: outcome})

      recommendation = if outcome == :pass, do: "PROCEED", else: "DO_NOT_PROCEED"
      sep            = if String.contains?(url, "?"), do: "&", else: "?"

      {:ok,
       url <> sep <> "response_gatewayRecommendation=#{recommendation}" <>
         "&authenticationTransactionId=#{auth_id}"}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Resolved 3DS2 status for a Hosted Session order that ran
  # INITIATE_AUTHENTICATION / AUTHENTICATE_PAYER before this PAY/AUTHORIZE.
  defp authentication_status_for(order_id) do
    case ThreeDSStore.get("order3ds:" <> order_id) do
      {:ok, %{stage: :authenticated, outcome: :pass}} -> "AUTHENTICATION_SUCCESSFUL"
      {:ok, %{stage: :authenticated, outcome: :fail}} -> "AUTHENTICATION_FAILED"
      _                                               -> "AUTHENTICATION_NOT_IN_EFFECT"
    end
  end

  # The PAN tokenised into the session by session.js's updateSessionFromForm
  # (POST .../session/:id/card), used to pick the 3DS2 test-card behaviour.
  defp session_pan(nil), do: nil

  defp session_pan(session_id) do
    case ThreeDSStore.get("session:" <> session_id) do
      {:ok, %{card: card}} when is_map(card) ->
        pan = Map.get(card, "number") || Map.get(card, "pan")
        if is_binary(pan) and pan != "", do: pan, else: nil

      _ ->
        nil
    end
  end

  # A full, self-contained issuer-style OTP page returned verbatim to the
  # payer's browser by the merchant server (AUTHENTICATE_PAYER.redirectHtml).
  # Its form posts the OTP back to the simulator, which then navigates the
  # browser to the merchant's redirectResponseUrl with the recommendation.
  defp authenticate_payer_redirect_html(auth_id, base_url) do
    action = "#{base_url}/3ds2/authenticate/#{auth_id}/verify"

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Identity Verification</title>
      <style>
        *, *::before, *::after { box-sizing: border-box; }
        body { font-family: Arial, Helvetica, sans-serif; background: transparent; margin: 0;
               min-height: 100vh; display: flex; align-items: center; justify-content: center;
               padding: 24px; }
        .card { width: 100%; max-width: 500px; background: #fff; border-radius: 12px;
                box-shadow: 0 10px 40px rgba(0,0,0,.18); overflow: hidden; }
        .bank-header { background: #003a70; color: #fff; padding: 18px 28px; font-size: 14px;
                       font-weight: 600; letter-spacing: .3px; }
        .body { padding: 28px 28px 24px; }
        h1 { font-size: 19px; margin: 0 0 8px; color: #1a1a2e; }
        p { font-size: 13px; color: #555; line-height: 1.6; margin: 0; }
        input[type=text] { width: 100%; padding: 14px; font-size: 20px;
                            letter-spacing: 4px; text-align: center; border: 1.5px solid #ccd3da;
                            border-radius: 8px; margin: 20px 0 4px; }
        button { width: 100%; padding: 14px; background: #003a70; color: #fff; border: 0;
                 border-radius: 8px; font-size: 15px; font-weight: 600; cursor: pointer; }
        .hint { font-size: 12px; color: #8a94a6; margin-top: 14px; text-align: center;
                line-height: 1.5; }
        .footer { padding: 14px 28px; font-size: 12px; color: #9aa4b2; text-align: center;
                  border-top: 1px solid #eef1f4; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="bank-header">Card Issuer &middot; Identity Verification</div>
        <div class="body">
          <h1>Verify your purchase</h1>
          <p>We've sent a one-time passcode to the mobile number on file for this card. Enter it below to complete your purchase.</p>
          <form method="POST" action="#{action}">
            <input type="text" name="otp" inputmode="numeric" maxlength="6" placeholder="Enter OTP" autofocus required>
            <button type="submit">Verify</button>
          </form>
          <div class="hint">Simulator: use code 123456 to approve, any other code to decline.</div>
        </div>
        <div class="footer">This is a simulated authentication screen for testing purposes.</div>
      </div>
    </body>
    </html>
    """
  end

  defp random_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end


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
