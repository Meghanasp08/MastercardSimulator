defmodule MastercardSimulator.Router do
  @moduledoc """
  Plug router that exposes the Mastercard Gateway REST API surface.

  Authenticated routes (HTTP Basic Auth required):
    PUT  /api/rest/version/:v/merchant/:mid/order/:oid/transaction/:tid
    GET  /api/rest/version/:v/merchant/:mid/order/:oid/transaction/:tid
    GET  /api/rest/version/:v/merchant/:mid/order/:oid
    POST /api/rest/version/:v/merchant/:mid/session
    PUT  /api/rest/version/:v/merchant/:mid/session/:sid
    GET  /admin/transactions

  Public routes (no auth):
    GET  /health
    GET  /static/checkout/checkout.min.js
    GET  /form/version/:v/merchant/:mid/session.js
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

  # PUT  /api/rest/version/:api_version/merchant/:merchant_id/session/:session_id
  put "/api/rest/version/:_api_version/merchant/:_merchant_id/session/:session_id" do
    body = conn.body_params || %{}

    Logger.info("Session update request for session: #{session_id}, body: #{inspect(body)}")

    send_json(conn, 200, %{
      "result" => "SUCCESS",
      "session" => %{
        "id" => session_id,
        "version" => "1"
      }
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

  defp send_js(conn, body) do
    conn
    |> put_resp_header("content-type", "application/javascript")
    |> send_resp(200, body)
  end

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

          el.innerHTML =
            '<div style="border:1px solid #ccc;padding:16px;font-family:sans-serif;">' +
            "<p><strong>MPGS Simulator &mdash; Embedded Payment Form</strong></p>" +
            "<p>Session: " + sessionId + "</p>" +
            '<label>Card Number <input id="mpgs-card-number" type="text" placeholder="4111111111111111"></label><br>' +
            '<label>Expiry Month <input id="mpgs-expiry-month" type="text" placeholder="12"></label>' +
            '<label>Expiry Year <input id="mpgs-expiry-year" type="text" placeholder="2030"></label><br>' +
            '<label>CVV <input id="mpgs-security-code" type="text" placeholder="123"></label>' +
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
      var FIELD_SPECS = {
        number:       { inputmode: "numeric", maxlength: 19, autocomplete: "cc-number",   errorKey: "cardNumber" },
        securityCode: { inputmode: "numeric", maxlength: 4,  autocomplete: "cc-csc",      errorKey: "securityCode" },
        expiryMonth:  { inputmode: "numeric", maxlength: 2,  autocomplete: "cc-exp-month", errorKey: "expiryMonth" },
        expiryYear:   { inputmode: "numeric", maxlength: 4,  autocomplete: "cc-exp-year",  errorKey: "expiryYear" }
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

          callback({ status: "ok" });
        }
      };
    })();
    """
  end
end
