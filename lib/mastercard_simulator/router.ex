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
    GET  /form/version/:v/merchant/:mid/session.js
    POST /form/version/:v/merchant/:mid/session/:sid/card   (session.js AJAX)
    POST /acs/:challenge_id[/verify]                        (3DS1 ACS challenge)
    GET  /3ds2/challenge/:auth_id                           (3DS2 challenge page)
    POST /3ds2/challenge/:auth_id/verify
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

  # PUT  /api/rest/version/:api_version/merchant/:merchant_id/session/:session_id
  put "/api/rest/version/:_api_version/merchant/:_merchant_id/session/:session_id" do
    body = conn.body_params || %{}

    Logger.info("Session update request for session: #{session_id}, body: #{inspect(body)}")

    store_session_3ds_context(session_id, body)

    send_json(conn, 200, %{
      "result" => "SUCCESS",
      "session" => %{
        "id" => session_id,
        "version" => "1"
      }
    })
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
  post "/form/version/:_api_version/merchant/:_merchant_id/session/:session_id/card" do
    card = conn.body_params || %{}
    pan  = Map.get(card, "number", "")

    if ThreeDSEngine.enrolled?(pan) do
      auth_id = "AUTH_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

      response_url =
        case ThreeDSStore.get("session:" <> session_id) do
          {:ok, %{response_url: url}} -> url
          _ -> nil
        end

      ThreeDSStore.put("auth:" <> auth_id, %{session_id: session_id, response_url: response_url})

      send_json(conn, 200, %{
        "status"       => "challenge_required",
        "challengeUrl" => "#{base_url(conn)}/3ds2/challenge/#{auth_id}"
      })
    else
      send_json(conn, 200, %{"status" => "ok"})
    end
  end

  # GET /3ds2/challenge/:auth_id — the actual "OTP page" the payer sees,
  # opened by session.js in an iframe overlay.
  get "/3ds2/challenge/:auth_id" do
    send_html(conn, otp_challenge_html("/3ds2/challenge/#{auth_id}/verify", []))
  end

  # POST /3ds2/challenge/:auth_id/verify — on success/failure, redirects the
  # TOP-LEVEL browser window back to CloudLayer's response_url, same as a
  # real 3DS2 challenge breaking out of its iframe at the end of the flow.
  post "/3ds2/challenge/:auth_id/verify" do
    otp = Map.get(conn.body_params || %{}, "otp", "")
    outcome = if ThreeDSEngine.valid_otp?(otp), do: :pass, else: :fail

    response_url =
      case ThreeDSStore.get("auth:" <> auth_id) do
        {:ok, %{response_url: url}} -> url
        _ -> nil
      end

    recommendation = if outcome == :pass, do: "PROCEED", else: "DO_NOT_PROCEED"

    if response_url do
      target =
        response_url <>
          if(String.contains?(response_url, "?"), do: "&", else: "?") <>
          "response_gatewayRecommendation=#{recommendation}&authenticationTransactionId=#{auth_id}"

      send_html(conn, redirect_top_html(target))
    else
      send_html(conn, no_response_url_html(recommendation))
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
        .card { max-width: 380px; margin: 40px auto; background: #fff; border-radius: 8px;
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
      window.Checkout = {
        _config: null,

        configure: function (options) {
          this._config = options || {};
          console.log("[MPGS Simulator] Checkout.configure", this._config);
        },

        showEmbeddedPage: function (selector) {
          var el = document.querySelector(selector);
          if (!el) {
            console.warn("[MPGS Simulator] showEmbeddedPage: no element for selector", selector);
            return;
          }

          var sessionId =
            (this._config && this._config.session && this._config.session.id) || "UNKNOWN_SESSION";

          // These are empty placeholder containers, not live inputs — an
          // <input> nested inside another <input> (which is what happens if
          // session.js injects into an id that's already an <input> here)
          // is legal markup but never focusable/typable in a browser.
          // PaymentSession.configure() (session.js) injects the real
          // fillable fields into these containers, matching real MPGS,
          // where Checkout renders the page shell and PaymentSession owns
          // the fields.
          el.innerHTML =
            '<div style="border:1px solid #ccc;padding:16px;font-family:sans-serif;">' +
            "<p><strong>MPGS Simulator &mdash; Embedded Payment Form</strong></p>" +
            "<p>Session: " + sessionId + "</p>" +
            '<label>Card Number <span id="mpgs-card-number"></span></label><br>' +
            '<label>Expiry Month <span id="mpgs-expiry-month"></span></label>' +
            '<label>Expiry Year <span id="mpgs-expiry-year"></span></label><br>' +
            '<label>Expiry (MM/YY) <span id="mpgs-expiry-date"></span></label><br>' +
            '<label>CVV <span id="mpgs-security-code"></span></label>' +
            "</div>";
        },

        showPaymentPage: function () {
          console.log("[MPGS Simulator] Checkout.showPaymentPage", this._config);
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

          var self = this;
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

          // Real MPGS attaches the card to the session server-side at this
          // point (the merchant's backend never sees the PAN) — this is also
          // where a 3DS2-enrolled card triggers the actual OTP challenge.
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
            .then(function (r) { return r.json(); })
            .then(function (result) {
              if (result && result.status === "challenge_required") {
                self._openChallenge(result.challengeUrl);
              } else {
                callback({ status: "ok" });
              }
            })
            .catch(function (err) {
              console.error("[MPGS Simulator] session/:id/card request failed", err);
              callback({ status: "ok" });
            });
        },

        // Opens the 3DS2 challenge page in an overlay iframe — this is the
        // actual OTP page the payer sees. The challenge page itself redirects
        // the top-level window to the merchant's response_url when done, so
        // there is nothing further for this function to do afterwards.
        _openChallenge: function (url) {
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
      };
    })();
    """
  end
end
