defmodule MastercardSimulator.ThreeDSEngine do
  @moduledoc """
  Decides 3-D Secure enrollment / challenge requirements for test PANs, and
  encodes/decodes the mock PaRes-equivalent pass/fail payload shared by the
  simulated 3DS1 ACS and 3DS2 challenge pages.

  Test PAN matrix (first 8 digits)
  ──────────────────────────────────────────────────────────────────────────
  4000 0000 xxxx xxxx    NOT enrolled — frictionless, no challenge shown
  everything else        Enrolled — challenge required (default)
  ──────────────────────────────────────────────────────────────────────────

  Fixed OTP for repeatable manual/automated testing: 123456 (any other value
  fails the challenge).
  """

  @frictionless_prefixes ["40000000"]
  @fixed_otp "123456"

  @doc "Whether this PAN requires a 3DS challenge (true) or is frictionless (false)."
  def enrolled?(pan) do
    not prefix_match?(clean_pan(pan), @frictionless_prefixes)
  end

  @doc "Whether a submitted OTP matches the fixed test code."
  def valid_otp?(submitted), do: submitted == @fixed_otp

  @doc "Encode a :pass/:fail outcome as the opaque base64 payload passed as PaRes."
  def encode_result(status) when status in [:pass, :fail] do
    %{"status" => Atom.to_string(status)}
    |> Jason.encode!()
    |> Base.encode64()
  end

  @doc "Decode a PaRes-equivalent payload back to :pass or :fail (defaults to :fail)."
  def decode_result(encoded) do
    with encoded when is_binary(encoded) <- encoded,
         {:ok, json} <- Base.decode64(encoded),
         {:ok, %{"status" => "pass"}} <- Jason.decode(json) do
      :pass
    else
      _ -> :fail
    end
  end

  defp clean_pan(nil), do: ""
  defp clean_pan(pan), do: String.replace(pan, ~r/[^0-9]/, "")

  defp prefix_match?(pan, prefixes) do
    Enum.any?(prefixes, fn p -> String.starts_with?(pan, String.slice(p, 0, 8)) end)
  end
end
