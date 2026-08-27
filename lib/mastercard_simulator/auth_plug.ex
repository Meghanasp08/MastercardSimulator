defmodule MastercardSimulator.AuthPlug do
  @moduledoc """
  HTTP Basic Auth middleware for the MPGS simulator.
  Paths in @public_paths, plus the browser-loaded MPGS script routes,
  bypass authentication entirely.
  Credentials are compared in constant time to prevent timing attacks.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  # Paths that do NOT require authentication
  @public_paths ["/health", "/static/checkout/checkout.min.js"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  # CORS preflight requests never carry the merchant's Basic Auth credentials
  # (browsers don't attach them to an OPTIONS preflight), so they must always
  # be allowed through — the real request behind them still gets checked.
  def call(%{method: "OPTIONS"} = conn, _opts), do: conn

  def call(%{request_path: path} = conn, _opts) do
    if public_path?(path) do
      conn
    else
      authenticate(conn)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] -> validate_basic(conn, encoded)
      _                     -> unauthorized(conn)
    end
  end

  defp public_path?(path) do
    path in @public_paths or session_js_path?(path) or session_card_path?(path) or
      acs_path?(path) or three_ds2_challenge_path?(path)
  end

  # GET /form/version/:version/merchant/:merchant_id/session.js is loaded
  # directly by the browser and must be reachable without credentials.
  defp session_js_path?(path) do
    case String.split(path, "/", trim: true) do
      ["form", "version", _version, "merchant", _merchant_id, "session.js"] -> true
      _ -> false
    end
  end

  # POST .../session/:id/card — session.js's own browser-side AJAX call that
  # attaches card data to the session; the cardholder's browser calls this
  # directly, so it can't carry the merchant's Basic Auth credentials.
  defp session_card_path?(path) do
    case String.split(path, "/", trim: true) do
      ["form", "version", _version, "merchant", _merchant_id, "session", _session_id, "card"] -> true
      _ -> false
    end
  end

  # POST /acs/:challenge_id[/verify] — the simulated 3DS1 ACS challenge page,
  # hit directly by the cardholder's browser after an auto-post redirect.
  defp acs_path?(path) do
    case String.split(path, "/", trim: true) do
      ["acs", _challenge_id] -> true
      ["acs", _challenge_id, "verify"] -> true
      _ -> false
    end
  end

  # GET/POST /3ds2/challenge/:auth_id[/verify] — the simulated 3DS2 hosted
  # challenge page opened by session.js in an iframe overlay.
  defp three_ds2_challenge_path?(path) do
    case String.split(path, "/", trim: true) do
      ["3ds2", "challenge", _auth_id] -> true
      ["3ds2", "challenge", _auth_id, "verify"] -> true
      _ -> false
    end
  end

  defp validate_basic(conn, encoded) do
    with {:ok, decoded}             <- Base.decode64(encoded),
         [username, password | _]   <- String.split(decoded, ":", parts: 2) do
      expected_user = Application.get_env(:mastercard_simulator, :api_username, "merchant.TEST_MERCHANT")
      expected_pass = Application.get_env(:mastercard_simulator, :api_password, "test_password_123")

      # Constant-time comparison – prevents timing-based credential enumeration
      user_ok = Plug.Crypto.secure_compare(username, expected_user)
      pass_ok = Plug.Crypto.secure_compare(password, expected_pass)

      if user_ok and pass_ok do
        conn
      else
        Logger.warning("[AuthPlug] Failed authentication attempt for user: #{username}")
        unauthorized(conn)
      end
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    body = Jason.encode!(%{
      "error" => %{
        "cause"       => "INVALID_CREDENTIALS",
        "explanation" => "Invalid API credentials. Use HTTP Basic Auth with your Merchant API credentials."
      },
      "result"  => "ERROR",
      "version" => "77"
    })

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("www-authenticate", ~s(Basic realm="Mastercard Gateway Simulator"))
    |> send_resp(401, body)
    |> halt()
  end
end
