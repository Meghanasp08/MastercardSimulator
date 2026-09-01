defmodule MastercardSimulator.Router do
  @moduledoc """
  Plug router that exposes the Mastercard Gateway REST API surface.

  Authenticated routes (HTTP Basic Auth required):
    PUT  /api/rest/version/:v/merchant/:mid/order/:oid/transaction/:tid
    GET  /api/rest/version/:v/merchant/:mid/order/:oid/transaction/:tid
    GET  /api/rest/version/:v/merchant/:mid/order/:oid
    POST /api/rest/version/:v/merchant/:mid/session
    PUT  /api/rest/version/:v/merchant/:mid/session/:sid
    POST /api/rest/version/:v/merchant/:mid/3DSecureId/:id
    GET  /admin/transactions

  Public routes (no auth):
    GET  /health
    GET  /static/checkout/checkout.min.js
    GET  /static/checkout/session/:sid/context              (checkout.min.js AJAX)
    GET  /form/version/:v/merchant/:mid/session.js
    POST /form/version/:v/merchant/:mid/session/:sid/card   (session.js AJAX)
    POST /acs/:challenge_id[/verify]                        (3DS1 ACS challenge)
    GET  /3ds2/challenge/:auth_id                           (3DS2 Hosted Checkout challenge page)
    POST /3ds2/challenge/:auth_id/verify
    POST /3ds2/authenticate/:auth_id/verify                 (3DS2 Hosted Session AUTHENTICATE_PAYER OTP)

  The PUT transaction route also accepts apiOperation INITIATE_AUTHENTICATION
  and AUTHENTICATE_PAYER (3DS2 for Hosted Session — the merchant server drives
  the challenge, not session.js).
  """

  use Plug.Router
  require Logger

  alias MastercardSimulator.{AuthPlug, TransactionHandler, TransactionStore, ThreeDSStore, ThreeDSEngine}

  # ── Plug pipeline ─────────────────────────────────────────────────────────────
  # Order matters:
  #   1. :match   – identify the route
  #   2. Logger   – log the request
  #   3. Parsers  – decode JSON / form-urlencoded bodies (form-encoded is used
  #      by the browser-posted ACS/challenge OTP forms)
  #   4. AuthPlug – verify credentials (skips /health and browser-facing routes)
  #   5. :dispatch – run the route handler

  plug :match

  plug Plug.Logger, log: :info

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["application/json", "application/*", "*/*"],
    json_decoder: Jason

  # session.js calls session/:id/card via a cross-origin fetch (the checkout
  # page and this simulator run on different origins/ports) — that requires
  # CORS headers on every response and a handled OPTIONS preflight, or the
  # browser silently blocks the request before it ever reaches AuthPlug.
  plug :put_cors_headers

  plug AuthPlug

  plug :dispatch

  # ── CORS preflight ────────────────────────────────────────────────────────────

  options _ do
    send_resp(conn, 204, "")
  end

  # ── Public route ─────────────────────────────────────────────────────────────

  get "/health" do
    send_json(conn, 200, %{
      status:  "UP",
      service: "Mastercard Gateway Simulator",
      version: "77",
      time:    DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  # ── MPGS browser-loaded scripts (no auth — see AuthPlug) ─────────────────────

  # GET  /static/checkout/checkout.min.js
  get "/static/checkout/checkout.min.js" do
    send_js(conn, checkout_js())
  end

  # GET  /form/version/:api_version/merchant/:merchant_id/session.js
  get "/form/version/:_api_version/merchant/:_merchant_id/session.js" do
    send_js(conn, session_js())
  end

  # ── MPGS Transaction API ──────────────────────────────────────────────────────

  # PUT  /api/rest/version/:api_version/merchant/:merchant_id/order/:order_id/transaction/:transaction_id
  put "/api/rest/version/:_api_version/merchant/:merchant_id/order/:order_id/transaction/:transaction_id" do
    body = conn.body_params || %{}

    case TransactionHandler.handle(merchant_id, order_id, transaction_id, body, base_url(conn)) do
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
    body = conn.body_params || %{}

    # Generate a unique session ID
    session_id = "SESSION_" <> (:crypto.strong_rand_bytes(8) |> Base.encode64() |> String.replace(["+", "/"], ""))

    Logger.info("Session creation request from merchant: #{merchant_id}")

    store_session_3ds_context(session_id, body)

    if Map.get(body, "apiOperation") == "INITIATE_CHECKOUT" do
      success_indicator = "SI_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
      store_checkout_context(session_id, body, success_indicator, merchant_id)

      send_json(conn, 201, %{
        "session" => %{
          "id" => session_id,
          "created" => DateTime.to_iso8601(DateTime.utc_now()),
          "updated" => DateTime.to_iso8601(DateTime.utc_now()),
          "validityPeriod" => 3600,
          "merchant" => merchant_id
        },
        "successIndicator" => success_indicator,
        "result" => "SUCCESS",
        "version" => "77"
      })
    else
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
  end

  # PUT  /api/rest/version/:api_version/merchant/:merchant_id/session/:session_id
  put "/api/rest/version/:_api_version/merchant/:merchant_id/session/:session_id" do
    body = conn.body_params || %{}

    Logger.info("Session update request for session: #{session_id}, body: #{inspect(body)}")

    store_session_3ds_context(session_id, body)
    store_checkout_context(session_id, body, nil, merchant_id)

    send_json(conn, 200, %{
      "result" => "SUCCESS",
      "session" => %{
        "id" => session_id,
        "version" => "1"
      }
    })
  end

  # GET /static/checkout/session/:session_id/context — checkout.min.js's own
  # AJAX call to fetch the returnUrl/successIndicator recorded at
  # INITIATE_CHECKOUT time, so it knows where to send the browser back to.
  get "/static/checkout/session/:session_id/context" do
    context =
      case ThreeDSStore.get("session:" <> session_id) do
        {:ok, data} -> data
        {:error, :not_found} -> %{}
      end

    send_json(conn, 200, %{
      "returnUrl"        => Map.get(context, :return_url),
      "successIndicator" => Map.get(context, :success_indicator),
      "merchantName"     => Map.get(context, :merchant_name),
      "merchantLogo"     => Map.get(context, :merchant_logo),
      "amount"           => Map.get(context, :amount),
      "currency"         => Map.get(context, :currency)
    })
  end

  # POST /static/checkout/session/:session_id/complete — checkout.min.js
  # calls this when the payer clicks Pay, so the simulator actually creates
  # a transaction record for the order server-side (same PAY logic and test
  # PAN scheme as the REST API), before redirecting the browser back with
  # resultIndicator. Without this, the order the merchant looks up via
  # GET .../order/:order_id would have no transaction at all — indistinguishable
  # from a payment that never went through the gateway.
  post "/static/checkout/session/:session_id/complete" do
    card = conn.body_params || %{}
    pan  = Map.get(card, "number", "")

    context = fetch_session_context(session_id)
    order_id    = Map.get(context, :order_id)
    merchant_id = Map.get(context, :merchant_id)

    cond do
      is_nil(order_id) or is_nil(merchant_id) ->
        send_json(conn, 422, %{
          "status"  => "error",
          "message" => "No order/merchant recorded for this checkout session"
        })

      ThreeDSEngine.enrolled?(pan) ->
        auth_id = "AUTH_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
        ThreeDSStore.put("auth:" <> auth_id, %{kind: :checkout, session_id: session_id, card: card})

        send_json(conn, 200, %{
          "status"       => "challenge_required",
          "challengeUrl" => "#{base_url(conn)}/3ds2/challenge/#{auth_id}"
        })

      true ->
        case run_checkout_payment(order_id, merchant_id, context, card, base_url(conn)) do
          {:approved, _response} ->
            send_json(conn, 200, %{"status" => "approved"})

          {:declined, response} ->
            send_json(conn, 200, %{
              "status"  => "declined",
              "message" => get_in(response, ["response", "acquirerMessage"])
            })
        end
    end
  end

  # POST /api/rest/version/:api_version/merchant/:merchant_id/3DSecureId/:three_ds_id
  # PROCESS_ACS_RESULT — CloudLayer's backend reports the decoded ACS PaRes here.
  post "/api/rest/version/:_api_version/merchant/:_merchant_id/3DSecureId/:three_ds_id" do
    body = conn.body_params || %{}

    case TransactionHandler.process_acs_result(three_ds_id, body) do
      {:ok, status, response} -> send_json(conn, status, response)
    end
  end

  # ── 3DS1 ACS challenge (no auth — browser-posted, see AuthPlug) ──────────────

  # POST /acs/:challenge_id — CloudLayer's browser auto-posts PaReq/TermUrl/MD
  # here (mirroring a real bank ACS); renders the OTP challenge page.
  post "/acs/:challenge_id" do
    params   = conn.body_params || %{}
    term_url = Map.get(params, "TermUrl", "")
    md       = Map.get(params, "MD", "")

    ThreeDSStore.merge("challenge:" <> challenge_id, %{term_url: term_url, md: md})

    send_html(conn, otp_challenge_html("/acs/#{challenge_id}/verify", [{"MD", md}]))
  end

  # POST /acs/:challenge_id/verify — OTP submission; auto-posts PaRes+MD back
  # to the merchant's TermUrl, exactly like a real ACS finishing the redirect.
  post "/acs/:challenge_id/verify" do
    otp = Map.get(conn.body_params || %{}, "otp", "")

    {term_url, md} =
      case ThreeDSStore.get("challenge:" <> challenge_id) do
        {:ok, %{term_url: term_url, md: md}} -> {term_url, md}
        _ -> {"", ""}
      end

    outcome = if ThreeDSEngine.valid_otp?(otp), do: :pass, else: :fail
    ThreeDSStore.merge("challenge:" <> challenge_id, %{status: outcome})
    pa_res = ThreeDSEngine.encode_result(outcome)

    send_html(conn, auto_submit_html(term_url, [{"PaRes", pa_res}, {"MD", md}]))
  end

  # ── 3DS2 hosted-session challenge (no auth — browser-driven, see AuthPlug) ───

  # POST /form/version/:v/merchant/:mid/session/:session_id/card
  # session.js's own AJAX call, made when the cardholder submits the form.
  # Hosted Session: this ONLY tokenises the card into the session. 3DS is
  # driven afterwards by the merchant server via INITIATE_AUTHENTICATION /
  # AUTHENTICATE_PAYER on the order transaction — session.js never runs the
  # challenge and never redirects in this flow.
  post "/form/version/:_api_version/merchant/:_merchant_id/session/:session_id/card" do
    card = conn.body_params || %{}

    ThreeDSStore.merge("session:" <> session_id, %{card: card})

    send_json(conn, 200, %{"status" => "ok"})
  end

  # GET /3ds2/challenge/:auth_id — the actual "OTP page" the payer sees,
  # opened by session.js in an iframe overlay.
  get "/3ds2/challenge/:auth_id" do
    send_html(conn, otp_challenge_html("/3ds2/challenge/#{auth_id}/verify", []))
  end

  # POST /3ds2/challenge/:auth_id/verify — on success/failure, redirects the
  # TOP-LEVEL browser window back to the merchant, same as a real 3DS2
  # challenge breaking out of its iframe at the end of the flow. Behavior
  # branches on which flow started the challenge (stored on the auth
  # record): Hosted Session redirects with response_gatewayRecommendation
  # and leaves PAY/AUTHORIZE to the merchant's own later REST call; Hosted
  # Checkout actually completes the order here (same as
  # /static/checkout/session/:id/complete's non-3DS path) before redirecting
  # with resultIndicator, since Checkout.js never gives the merchant a
  # separate chance to call PAY themselves.
  post "/3ds2/challenge/:auth_id/verify" do
    otp = Map.get(conn.body_params || %{}, "otp", "")
    outcome = if ThreeDSEngine.valid_otp?(otp), do: :pass, else: :fail

    case ThreeDSStore.get("auth:" <> auth_id) do
      {:ok, %{kind: :checkout} = auth} ->
        send_html(conn, checkout_challenge_result_html(auth, outcome, base_url(conn)))

      {:ok, auth} ->
        send_html(conn, session_challenge_result_html(auth_id, auth, outcome))

      {:error, :not_found} ->
        send_html(conn, no_response_url_html(if(outcome == :pass, do: "PROCEED", else: "DO_NOT_PROCEED")))
    end
  end

  # ── 3DS2 Hosted Session AUTHENTICATE_PAYER challenge (no auth — browser) ─────

  # POST /3ds2/authenticate/:auth_id/verify — the OTP form inside the
  # AUTHENTICATE_PAYER redirectHtml posts here. On completion the simulator
  # navigates the payer's browser back to the merchant's redirectResponseUrl
  # with response_gatewayRecommendation appended (PROCEED / DO_NOT_PROCEED).
  # The merchant server then calls PAY/AUTHORIZE on the same order.
  post "/3ds2/authenticate/:auth_id/verify" do
    otp = Map.get(conn.body_params || %{}, "otp", "")

    case TransactionHandler.complete_authenticate_payer(auth_id, otp) do
      {:ok, target_url}    -> send_html(conn, redirect_top_html(target_url))
      {:error, :not_found} -> send_html(conn, no_response_url_html("DO_NOT_PROCEED"))
    end
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

  defp put_cors_headers(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_js(conn, body) do
    conn
    |> put_resp_header("content-type", "application/javascript")
    |> send_resp(200, body)
  end

  defp send_html(conn, body) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, body)
  end

  defp base_url(conn) do
    "#{conn.scheme}://#{conn.host}:#{conn.port}"
  end

  # Record whatever 3DS2 context (currently just response_url) the caller
  # supplied at session create/update time, so the /session/:id/card and
  # /3ds2/challenge/:auth_id/verify handlers can look it up later.
  defp store_session_3ds_context(session_id, body) do
    case Map.get(body, "response_url") do
      nil -> :ok
      response_url -> ThreeDSStore.merge("session:" <> session_id, %{response_url: response_url})
    end
  end

  # Record Hosted Checkout context (interaction.returnUrl, successIndicator,
  # interaction.merchant.name/logo, order.id/amount/currency, merchant_id)
  # against the session, so /static/checkout/session/:id/context (fetched by
  # checkout.min.js in the browser) can hand back what it needs to render the
  # branded payment UI and to actually complete the order server-side (see
  # /static/checkout/session/:id/complete) before redirecting back to the
  # merchant. success_indicator is only generated at INITIATE_CHECKOUT time —
  # pass nil on later session updates to leave whatever was already stored
  # untouched.
  defp store_checkout_context(session_id, body, success_indicator, merchant_id) do
    return_url    = get_in(body, ["interaction", "returnUrl"])
    merchant_name = get_in(body, ["interaction", "merchant", "name"])
    merchant_logo = get_in(body, ["interaction", "merchant", "logo"])
    order         = Map.get(body, "order", %{})

    changes =
      %{}
      |> maybe_put(:return_url, return_url)
      |> maybe_put(:success_indicator, success_indicator)
      |> maybe_put(:merchant_name, merchant_name)
      |> maybe_put(:merchant_logo, merchant_logo)
      |> maybe_put(:amount, Map.get(order, "amount"))
      |> maybe_put(:currency, Map.get(order, "currency"))
      |> maybe_put(:order_id, Map.get(order, "id"))
      |> maybe_put(:merchant_id, merchant_id)

    if map_size(changes) > 0 do
      ThreeDSStore.merge("session:" <> session_id, changes)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_session_context(session_id) do
    case ThreeDSStore.get("session:" <> session_id) do
      {:ok, data} -> data
      {:error, :not_found} -> %{}
    end
  end

  # Runs a Hosted Checkout order through the same PAY logic (and test-PAN
  # scheme) as the REST API, given the session's recorded order context and
  # the card entered in the checkout UI. Used both by the non-3DS path in
  # /static/checkout/session/:id/complete and by the post-OTP completion in
  # checkout_challenge_result_html/3.
  defp run_checkout_payment(order_id, merchant_id, context, card, base_url) do
    transaction_id = "TXN_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

    pay_body = %{
      "apiOperation" => "PAY",
      "order" => %{
        "amount"   => Map.get(context, :amount),
        "currency" => Map.get(context, :currency)
      },
      "sourceOfFunds" => %{
        "provided" => %{
          "card" => %{
            "number" => Map.get(card, "number"),
            "expiry" => %{
              "month" => Map.get(card, "expiryMonth"),
              "year"  => Map.get(card, "expiryYear")
            }
          }
        }
      }
    }

    {:ok, _status, response} =
      TransactionHandler.handle(merchant_id, order_id, transaction_id, pay_body, base_url)

    case response["result"] do
      "SUCCESS" -> {:approved, response}
      _ -> {:declined, response}
    end
  end

  defp append_query(url, kv) do
    url <> if(String.contains?(url, "?"), do: "&", else: "?") <> kv
  end

  # Hosted Session's post-challenge redirect: report the recommendation and
  # let the merchant's own subsequent REST call actually run PAY/AUTHORIZE.
  defp session_challenge_result_html(auth_id, auth, outcome) do
    response_url = Map.get(auth, :response_url)
    recommendation = if outcome == :pass, do: "PROCEED", else: "DO_NOT_PROCEED"

    if response_url do
      target = append_query(response_url, "response_gatewayRecommendation=#{recommendation}&authenticationTransactionId=#{auth_id}")
      redirect_top_html(target)
    else
      no_response_url_html(recommendation)
    end
  end

  # Hosted Checkout's post-challenge redirect: Checkout.js never gives the
  # merchant a separate chance to call PAY, so a passed OTP actually
  # completes the order here before redirecting with resultIndicator. A
  # failed OTP skips completion entirely — no transaction is created, and no
  # resultIndicator is returned, so the merchant's comparison fails closed.
  defp checkout_challenge_result_html(auth, :fail, _base_url) do
    context = fetch_session_context(Map.get(auth, :session_id))

    case Map.get(context, :return_url) do
      nil -> no_response_url_html("DO_NOT_PROCEED")
      return_url -> redirect_top_html(append_query(return_url, "resultIndicator="))
    end
  end

  defp checkout_challenge_result_html(auth, :pass, base_url) do
    session_id = Map.get(auth, :session_id)
    card       = Map.get(auth, :card, %{})
    context    = fetch_session_context(session_id)

    order_id          = Map.get(context, :order_id)
    merchant_id       = Map.get(context, :merchant_id)
    return_url        = Map.get(context, :return_url)
    success_indicator = Map.get(context, :success_indicator)

    result_indicator =
      if order_id && merchant_id do
        case run_checkout_payment(order_id, merchant_id, context, card, base_url) do
          {:approved, _response} -> success_indicator
          {:declined, _response} -> nil
        end
      end

    case return_url do
      nil -> no_response_url_html(if(result_indicator, do: "PROCEED", else: "DO_NOT_PROCEED"))
      _ -> redirect_top_html(append_query(return_url, "resultIndicator=#{result_indicator}"))
    end
  end

  # ── 3DS challenge / ACS pages ────────────────────────────────────────────────

  # Generic bank-style OTP challenge page shared by the 3DS1 ACS and the
  # 3DS2 hosted-session challenge — deliberately not styled like this
  # simulator/merchant brand, to resemble a real issuer's authentication
  # screen. Accepts the fixed test code 123456; anything else fails.
  defp otp_challenge_html(action_path, hidden_fields) do
    hidden_html =
      hidden_fields
      |> Enum.map(fn {name, value} ->
        ~s(<input type="hidden" name="#{html_escape(name)}" value="#{html_escape(value)}">)
      end)
      |> Enum.join("\n        ")

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Identity Verification</title>
      <style>
        body { font-family: Arial, Helvetica, sans-serif; background: #eef1f4; margin: 0; }
        .card { max-width: 420px; margin: 40px auto; background: #fff; border-radius: 8px;
                box-shadow: 0 4px 16px rgba(0,0,0,.15); overflow: hidden; }
        .bank-header { background: #003a70; color: #fff; padding: 16px 20px; font-size: 14px;
                       font-weight: 600; letter-spacing: .3px; }
        .body { padding: 24px; }
        h1 { font-size: 18px; margin: 0 0 8px; color: #1a1a2e; }
        p { font-size: 13px; color: #555; line-height: 1.5; }
        input[type=text] { width: 100%; box-sizing: border-box; padding: 12px; font-size: 20px;
                            letter-spacing: 4px; text-align: center; border: 1.5px solid #ccd3da;
                            border-radius: 6px; margin: 16px 0; }
        button { width: 100%; padding: 12px; background: #003a70; color: #fff; border: 0;
                 border-radius: 6px; font-size: 15px; font-weight: 600; cursor: pointer; }
        .hint { font-size: 11px; color: #8a94a6; margin-top: 10px; text-align: center; }
        .footer { padding: 12px 24px; font-size: 11px; color: #9aa4b2; text-align: center;
                  border-top: 1px solid #eef1f4; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="bank-header">Card Issuer &middot; Identity Verification</div>
        <div class="body">
          <h1>Verify your purchase</h1>
          <p>We've sent a one-time passcode to the mobile number on file for this card. Enter it below to complete your purchase.</p>
          <form method="POST" action="#{html_escape(action_path)}">
            #{hidden_html}
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

  # Auto-submitting hidden form used to hand PaRes/MD back to the merchant's
  # TermUrl — mirrors how a real ACS finishes the 3DS1 browser round-trip.
  defp auto_submit_html(target_url, hidden_fields) do
    hidden_html =
      hidden_fields
      |> Enum.map(fn {name, value} ->
        ~s(<input type="hidden" name="#{html_escape(name)}" value="#{html_escape(value)}">)
      end)
      |> Enum.join("\n      ")

    """
    <!DOCTYPE html>
    <html>
    <body onload="document.forms[0].submit()">
      <form method="POST" action="#{html_escape(target_url)}">
        #{hidden_html}
      </form>
      <p>Completing authentication&hellip;</p>
    </body>
    </html>
    """
  end

  # Navigates the TOP-LEVEL browser window (breaking out of the challenge
  # iframe) to the merchant's 3DS2 response_url with the outcome in the
  # query string.
  defp redirect_top_html(target_url) do
    """
    <!DOCTYPE html>
    <html>
    <body>
      <script>window.top.location.href = #{Jason.encode!(target_url)};</script>
      <p>Completing authentication&hellip;</p>
    </body>
    </html>
    """
  end

  defp no_response_url_html(recommendation) do
    """
    <!DOCTYPE html>
    <html>
    <body>
      <p>Authentication result: #{html_escape(recommendation)}</p>
      <p>No response_url was configured for this session, so the simulator could not redirect back to the merchant.</p>
    </body>
    </html>
    """
  end

  defp html_escape(value), do: Plug.HTML.html_escape(to_string(value))

  # ── Mock MPGS browser scripts ────────────────────────────────────────────────

  defp checkout_js do
    """
    (function () {
      var CURRENT_SCRIPT = document.currentScript;
      var SCRIPT_SRC = CURRENT_SCRIPT ? CURRENT_SCRIPT.src : "";
      var MARKER_IDX = SCRIPT_SRC.indexOf("/static/checkout/checkout.min.js");
      var SCRIPT_ORIGIN = MARKER_IDX >= 0 ? SCRIPT_SRC.slice(0, MARKER_IDX) : "";

      // Real MPGS invokes the merchant's own named callback functions (given
      // as script-tag attributes) when the payer cancels or an error occurs.
      var ERROR_FN_NAME = CURRENT_SCRIPT ? CURRENT_SCRIPT.getAttribute("data-error") : null;
      var CANCEL_FN_NAME = CURRENT_SCRIPT ? CURRENT_SCRIPT.getAttribute("data-cancel") : null;

      function fetchContext(sessionId) {
        return fetch(SCRIPT_ORIGIN + "/static/checkout/session/" + sessionId + "/context")
          .then(function (r) { return r.json(); });
      }

      function completeWithResult(returnUrl, successIndicator) {
        if (!returnUrl) {
          console.warn("[MPGS Simulator] Checkout: no returnUrl configured for this session (interaction.returnUrl)");
          return;
        }
        var separator = returnUrl.indexOf("?") >= 0 ? "&" : "?";
        window.location.href = returnUrl + separator + "resultIndicator=" + encodeURIComponent(successIndicator || "");
      }

      // Opens the 3DS challenge page in an overlay iframe — the actual OTP
      // page the payer sees. That page completes the order and redirects
      // the top-level window itself once verified, so nothing further
      // happens here.
      function openChallenge(url) {
        var overlay = document.createElement("div");
        overlay.style.cssText =
          "position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.6);" +
          "z-index:999999;display:flex;align-items:center;justify-content:center;";

        var iframe = document.createElement("iframe");
        iframe.src = url;
        iframe.style.cssText =
          "width:400px;height:520px;max-width:95%;max-height:95%;border:none;" +
          "border-radius:12px;background:#fff;box-shadow:0 10px 40px rgba(0,0,0,.3);";

        overlay.appendChild(iframe);
        document.body.appendChild(overlay);
      }

      function triggerCancel() {
        if (CANCEL_FN_NAME && typeof window[CANCEL_FN_NAME] === "function") {
          window[CANCEL_FN_NAME]();
        } else {
          console.warn("[MPGS Simulator] Checkout: payer cancelled, but no data-cancel callback is configured");
        }
      }

      function triggerError() {
        if (ERROR_FN_NAME && typeof window[ERROR_FN_NAME] === "function") {
          window[ERROR_FN_NAME]({ cause: "SIMULATOR_ERROR", explanation: "Simulated Checkout.js error for testing" });
        } else {
          console.warn("[MPGS Simulator] Checkout: simulated error, but no data-error callback is configured");
        }
      }

      function escapeHtml(value) {
        var div = document.createElement("div");
        div.textContent = value == null ? "" : String(value);
        return div.innerHTML;
      }

      function formatAmount(ctx) {
        if (ctx.amount == null) return "";
        return (ctx.currency ? ctx.currency + " " : "") + Number(ctx.amount).toFixed(2);
      }

      // Branding matches the Hosted Session card page (session_page/1 in
      // mastercard_controller.ex) so both flows look consistent in local
      // testing. Real Checkout.js only ever lets a merchant pass a
      // name/logo — it never lets the merchant restyle the page itself —
      // so this is the simulator's own presentation layer, not something
      // driven by additional INITIATE_CHECKOUT parameters beyond
      // interaction.merchant.name/logo and order.amount/currency.
      function cardHtml(ctx) {
        var logoHtml = ctx.merchantLogo
          ? '<img src="' + escapeHtml(ctx.merchantLogo) + '" alt="" style="width:64px;height:64px;object-fit:contain;">'
          : '<span style="font-size:28px;font-weight:700;color:#7f496c;">' +
            escapeHtml((ctx.merchantName || "M").charAt(0).toUpperCase()) + "</span>";

        var amountHtml = formatAmount(ctx)
          ? '<div style="font-size:20px;font-weight:700;">Amount: ' + escapeHtml(formatAmount(ctx)) + "</div>"
          : "";

        return (
          '<div style="max-width:520px;margin:0 auto;font-family:Arial,Helvetica,sans-serif;' +
          'background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 10px 30px rgba(0,0,0,.08);">' +
            '<div style="background:linear-gradient(135deg,#ca355f 0%,#7f496c 100%);color:#fff;' +
            'padding:24px 24px 20px;text-align:center;">' +
              '<div style="width:72px;height:72px;margin:0 auto 10px;border-radius:999px;background:#fff;' +
              'display:flex;align-items:center;justify-content:center;box-shadow:0 10px 24px rgba(30,18,42,.18);' +
              'overflow:hidden;">' + logoHtml + "</div>" +
              (ctx.merchantName ? '<div style="font-weight:600;margin-bottom:4px;">' + escapeHtml(ctx.merchantName) + "</div>" : "") +
              amountHtml +
            "</div>" +
            '<div style="padding:24px;">' +
              field_row("Card number", '<span id="mpgs-card-number" style="width:100%;height:100%;display:block;"></span>') +
              '<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;">' +
                "<div>" +
                  field_row("Expiry (MM/YY)", '<span id="mpgs-expiry-date" style="width:100%;height:100%;display:block;"></span>') +
                "</div>" +
                "<div>" +
                  field_row("CVV", '<span id="mpgs-security-code" style="width:100%;height:100%;display:block;"></span>') +
                "</div>" +
              "</div>" +
              field_row("Name on card", '<span id="mpgs-name-on-card" style="width:100%;height:100%;display:block;"></span>') +
              '<button type="button" data-mpgs-action="pay" style="width:100%;margin-top:20px;padding:14px;border:0;' +
              'border-radius:10px;background:#121533;color:#fff;font-size:18px;font-weight:700;cursor:pointer;">Pay' +
              (formatAmount(ctx) ? " " + escapeHtml(formatAmount(ctx)) : "") + "</button>" +
              '<p id="mpgs-checkout-error" style="color:#dc2626;font-size:13px;text-align:center;margin:10px 0 0;min-height:16px;"></p>' +
              '<div style="margin-top:12px;text-align:center;">' +
                '<button type="button" data-mpgs-action="cancel" style="background:none;border:0;color:#6b7280;' +
                'font-size:13px;cursor:pointer;text-decoration:underline;margin-right:16px;">Cancel</button>' +
                '<button type="button" data-mpgs-action="error" style="background:none;border:0;color:#6b7280;' +
                'font-size:13px;cursor:pointer;text-decoration:underline;">Simulate Error</button>' +
              "</div>" +
              '<p style="font-size:11px;color:#9aa4b2;text-align:center;margin-top:12px;">' +
              "Simulator: Pay uses the same test-card outcomes as the REST API; Cancel/Simulate Error exercise data-cancel/data-error.</p>" +
            "</div>" +
          "</div>"
        );
      }

      function field_row(labelText, innerHtml) {
        return (
          '<label style="display:block;font-size:12px;font-weight:700;color:#374151;text-transform:uppercase;' +
          'letter-spacing:.5px;margin:14px 0 6px;">' + escapeHtml(labelText) + "</label>" +
          field_box(innerHtml)
        );
      }

      function field_box(innerHtml) {
        return (
          '<div style="width:100%;height:48px;padding:0 14px;border:1.8px solid #d1d5db;border-radius:10px;' +
          'background:#fff;box-sizing:border-box;display:flex;align-items:center;">' + innerHtml + "</div>"
        );
      }

      // Real Checkout.js is self-contained — it injects and owns its own
      // card fields, it does not rely on a separately configured
      // PaymentSession/session.js. This injects a real, typable <input>
      // into each placeholder <span> the card markup renders.
      var CHECKOUT_FIELD_SPECS = {
        "mpgs-card-number":   { inputmode: "numeric", maxlength: 19, autocomplete: "cc-number" },
        "mpgs-expiry-date":   { inputmode: "numeric", maxlength: 5,  autocomplete: "cc-exp", placeholder: "MM/YY" },
        "mpgs-security-code": { inputmode: "numeric", maxlength: 4,  autocomplete: "cc-csc" },
        "mpgs-name-on-card":  { maxlength: 80, autocomplete: "cc-name", placeholder: "Name on card" }
      };

      function injectFields(container) {
        var inputs = {};

        Object.keys(CHECKOUT_FIELD_SPECS).forEach(function (id) {
          var span = container.querySelector("#" + id);
          if (!span) return;

          var spec = CHECKOUT_FIELD_SPECS[id];
          var input = document.createElement("input");
          input.type = "text";
          input.style.cssText = "border:none;outline:none;background:transparent;width:100%;height:100%;font-size:16px;";
          if (spec.inputmode) input.setAttribute("inputmode", spec.inputmode);
          if (spec.maxlength) input.setAttribute("maxlength", spec.maxlength);
          if (spec.autocomplete) input.setAttribute("autocomplete", spec.autocomplete);
          if (spec.placeholder) input.setAttribute("placeholder", spec.placeholder);

          if (id === "mpgs-expiry-date") {
            input.addEventListener("input", function () {
              var digits = input.value.replace(/[^0-9]/g, "").slice(0, 4);
              input.value = digits.length > 2 ? digits.slice(0, 2) + "/" + digits.slice(2) : digits;
            });
          }

          span.appendChild(input);
          inputs[id] = input;
        });

        return inputs;
      }

      function renderPaymentUi(container, sessionId) {
        container.innerHTML = '<p style="font-family:Arial,Helvetica,sans-serif;text-align:center;color:#888;">Loading payment form&hellip;</p>';

        fetchContext(sessionId).then(function (ctx) {
          container.innerHTML = cardHtml(ctx);
          var inputs = injectFields(container);
          var errorEl = container.querySelector("#mpgs-checkout-error");
          var payButton = container.querySelector('[data-mpgs-action="pay"]');

          payButton.addEventListener("click", function () {
            if (errorEl) errorEl.textContent = "";

            var cardNumber = inputs["mpgs-card-number"] ? inputs["mpgs-card-number"].value.trim() : "";
            if (!cardNumber) {
              if (errorEl) errorEl.textContent = "Please enter a card number.";
              return;
            }

            var expiryValue = inputs["mpgs-expiry-date"] ? inputs["mpgs-expiry-date"].value.trim() : "";
            var expiryParts = expiryValue.split("/");
            var securityCode = inputs["mpgs-security-code"] ? inputs["mpgs-security-code"].value.trim() : "";
            var nameOnCard = inputs["mpgs-name-on-card"] ? inputs["mpgs-name-on-card"].value.trim() : "";

            payButton.disabled = true;

            // Actually completes the order server-side (same test-card
            // outcomes as the REST PAY endpoint) before redirecting, so the
            // merchant's GET .../order/:order_id lookup finds a real,
            // approved transaction instead of nothing.
            fetch(SCRIPT_ORIGIN + "/static/checkout/session/" + sessionId + "/complete", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                number: cardNumber,
                expiryMonth: expiryParts[0] || "",
                expiryYear: expiryParts[1] || "",
                securityCode: securityCode,
                nameOnCard: nameOnCard
              })
            })
              .then(function (r) { return r.json(); })
              .then(function (result) {
                if (result.status === "challenge_required") {
                  // The challenge page itself completes the order and
                  // redirects the top-level window once the OTP is
                  // verified — nothing further to do here.
                  openChallenge(result.challengeUrl);
                } else if (result.status === "approved") {
                  completeWithResult(ctx.returnUrl, ctx.successIndicator);
                } else {
                  payButton.disabled = false;
                  if (errorEl) errorEl.textContent = result.message || "Payment could not be processed.";
                }
              })
              .catch(function (err) {
                payButton.disabled = false;
                console.error("[MPGS Simulator] Checkout: completion request failed", err);
                if (errorEl) errorEl.textContent = "Payment could not be processed.";
              });
          });
          container.querySelector('[data-mpgs-action="cancel"]').addEventListener("click", triggerCancel);
          container.querySelector('[data-mpgs-action="error"]').addEventListener("click", triggerError);
        });
      }

      window.Checkout = {
        _config: null,

        configure: function (options) {
          this._config = options || {};
          console.log("[MPGS Simulator] Checkout.configure", this._config);
        },

        // Embeds the payment UI inline into the target element. Field
        // containers are empty placeholder <span>s, not live inputs — an
        // <input> nested inside another <input> (which is what happens if
        // session.js injects into an id that's already an <input> here) is
        // legal markup but never focusable/typable in a browser.
        // PaymentSession.configure() (session.js) injects the real fillable
        // fields into these containers if the integrating page also uses it.
        showEmbeddedPage: function (selector) {
          var el = document.querySelector(selector);
          if (!el) {
            console.warn("[MPGS Simulator] showEmbeddedPage: no element for selector", selector);
            return;
          }

          var sessionId =
            (this._config && this._config.session && this._config.session.id) || "UNKNOWN_SESSION";

          renderPaymentUi(el, sessionId);
        },

        // Real MPGS fully navigates the browser away to a hosted payment
        // page; the simulator takes over the current document body instead.
        showPaymentPage: function () {
          var sessionId =
            (this._config && this._config.session && this._config.session.id) || "UNKNOWN_SESSION";

          console.log("[MPGS Simulator] Checkout.showPaymentPage", this._config);

          document.body.style.background = "#f0f4f8";
          document.body.style.margin = "0";
          document.body.style.padding = "40px 16px";
          document.body.style.boxSizing = "border-box";

          renderPaymentUi(document.body, sessionId);
        }
      };
    })();
    """
  end

  defp session_js do
    """
    (function () {
      // Capture where this script was loaded from so PaymentSession can call
      // back to the simulator's own origin (session.js itself carries no
      // config for its own base URL).
      var CURRENT_SCRIPT = document.currentScript;
      var SCRIPT_SRC = CURRENT_SCRIPT ? CURRENT_SCRIPT.src : "";
      var VERSION_MARKER = "/form/version/";
      var MARKER_IDX = SCRIPT_SRC.indexOf(VERSION_MARKER);
      var SCRIPT_ORIGIN = MARKER_IDX >= 0 ? SCRIPT_SRC.slice(0, MARKER_IDX) : "";
      var AFTER_VERSION = MARKER_IDX >= 0 ? SCRIPT_SRC.slice(MARKER_IDX + VERSION_MARKER.length).split("/") : [];
      var API_VERSION = AFTER_VERSION[0] || "77";
      var MERCHANT_ID = AFTER_VERSION[2] || "";

      var FIELD_SPECS = {
        number:       { inputmode: "numeric", maxlength: 19, autocomplete: "cc-number",   errorKey: "cardNumber" },
        securityCode: { inputmode: "numeric", maxlength: 4,  autocomplete: "cc-csc",      errorKey: "securityCode" },
        expiryMonth:  { inputmode: "numeric", maxlength: 2,  autocomplete: "cc-exp-month", errorKey: "expiryMonth" },
        expiryYear:   { inputmode: "numeric", maxlength: 4,  autocomplete: "cc-exp-year",  errorKey: "expiryYear" },
        // Combined MM/YY field — some integrating pages configure a single
        // selector for expiry instead of separate month/year selectors.
        expiryDate:   { inputmode: "numeric", maxlength: 5,  autocomplete: "cc-exp",       errorKey: "expiryDate", placeholder: "MM/YY" }
      };

      window.PaymentSession = {
        _config: null,
        _inputs: {},

        configure: function (options) {
          this._config = options || {};
          this._inputs = {};
          console.log("[MPGS Simulator] PaymentSession.configure", this._config);

          var fields = (this._config.fields && this._config.fields.card) || {};

          for (var name in fields) {
            if (!Object.prototype.hasOwnProperty.call(fields, name)) continue;

            var selector = fields[name];
            var container = document.querySelector(selector);
            if (!container) {
              console.warn("[MPGS Simulator] session.js: no element for selector", selector);
              continue;
            }

            var spec = FIELD_SPECS[name] || {};
            var input = document.createElement("input");
            input.type = "text";
            input.setAttribute("data-mpgs-field", name);
            if (spec.inputmode) input.setAttribute("inputmode", spec.inputmode);
            if (spec.maxlength) input.setAttribute("maxlength", spec.maxlength);
            if (spec.autocomplete) input.setAttribute("autocomplete", spec.autocomplete);
            if (spec.placeholder) input.setAttribute("placeholder", spec.placeholder);

            if (name === "expiryDate") {
              input.addEventListener("input", function () {
                var digits = input.value.replace(/[^0-9]/g, "").slice(0, 4);
                input.value = digits.length > 2 ? digits.slice(0, 2) + "/" + digits.slice(2) : digits;
              });
            }

            container.innerHTML = "";
            container.appendChild(input);
            this._inputs[name] = input;
          }

          if (this._config.callbacks && typeof this._config.callbacks.initialized === "function") {
            this._config.callbacks.initialized({ status: "ok" });
          }
        },

        updateSessionFromForm: function (type) {
          console.log("[MPGS Simulator] PaymentSession.updateSessionFromForm", type);

          var callback =
            this._config && this._config.callbacks && this._config.callbacks.formSessionUpdate;
          if (typeof callback !== "function") return;

          var cardNumberInput = this._inputs.number;
          var cardNumber = cardNumberInput ? cardNumberInput.value.trim() : "";

          if (!cardNumber) {
            callback({ status: "fields_in_error", errors: { cardNumber: true } });
            return;
          }

          var expiryMonth, expiryYear;

          if (this._inputs.expiryDate) {
            var expiryValue = this._inputs.expiryDate.value.trim();
            var match = /^(\\d{2})\\/?(\\d{2})$/.exec(expiryValue);
            if (!match) {
              callback({ status: "fields_in_error", errors: { expiryDate: true } });
              return;
            }
            expiryMonth = match[1];
            expiryYear = match[2];
          } else {
            expiryMonth = this._inputs.expiryMonth ? this._inputs.expiryMonth.value.trim() : "";
            expiryYear = this._inputs.expiryYear ? this._inputs.expiryYear.value.trim() : "";
          }

          var securityCode = this._inputs.securityCode ? this._inputs.securityCode.value.trim() : "";
          var sessionId = this._config.session;
          var cardUpdateUrl =
            SCRIPT_ORIGIN + "/form/version/" + API_VERSION + "/merchant/" + MERCHANT_ID +
            "/session/" + sessionId + "/card";

          // Hosted Session: this call only tokenises the card into the
          // session server-side (the merchant's backend never sees the PAN).
          // It does NOT run 3DS — the merchant server drives that afterwards
          // via the INITIATE_AUTHENTICATION / AUTHENTICATE_PAYER API. session.js
          // in this flow never shows a challenge and never redirects.
          fetch(cardUpdateUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              number: cardNumber,
              expiryMonth: expiryMonth,
              expiryYear: expiryYear,
              securityCode: securityCode
            })
          })
            .then(function () { callback({ status: "ok" }); })
            .catch(function (err) {
              console.error("[MPGS Simulator] session/:id/card request failed", err);
              callback({ status: "ok" });
            });
        }
      };
    })();
    """
  end
end
