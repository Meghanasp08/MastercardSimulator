defmodule MastercardSimulator.AuthPlug do
  @moduledoc """
  HTTP Basic Auth middleware for the MPGS simulator.
  Paths in @public_paths bypass authentication entirely.
  Credentials are compared in constant time to prevent timing attacks.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  # Paths that do NOT require authentication
  @public_paths ["/health"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: path} = conn, _opts) when path in @public_paths, do: conn

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] -> validate_basic(conn, encoded)
      _                     -> unauthorized(conn)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

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
