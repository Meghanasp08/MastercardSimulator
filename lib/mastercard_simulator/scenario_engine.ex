defmodule MastercardSimulator.ScenarioEngine do
  @moduledoc """
  Maps test card PANs and transaction amounts to specific gateway outcomes.

  Test card matrix
  ────────────────────────────────────────────────────────────────────────────
  Card prefix / full PAN      Scheme        Outcome
  ─────────────────────────── ───────────── ──────────────────────────────────
  5123 45xx xxxx xxxx         Mastercard    Approved
  5111 11xx xxxx xxxx         Mastercard    Approved
  4111 11xx xxxx xxxx         Visa          Approved
  4012 88xx xxxx xxxx         Visa          Approved
  3782 82xx xxxx xxxx         Amex          Approved
  5999 99xx xxxx xxxx         Mastercard    Declined (05 – Do Not Honour)
  4999 99xx xxxx xxxx         Visa          Declined (05 – Do Not Honour)
  5777 77xx xxxx xxxx         Mastercard    Declined (51 – Insufficient Funds)
  4777 77xx xxxx xxxx         Visa          Declined (51 – Insufficient Funds)
  5666 66xx xxxx xxxx         Mastercard    Declined (54 – Expired Card)
  4666 66xx xxxx xxxx         Visa          Declined (54 – Expired Card)
  5888 88xx xxxx xxxx         Mastercard    PIN Required (singleTap flow)
  4888 88xx xxxx xxxx         Visa          PIN Required (singleTap flow)
  Any PAN, amount > 99 999    any           Declined (61 – Exceeds Limit)
  ────────────────────────────────────────────────────────────────────────────
  """

  # First-8-digit prefixes for each scenario
  # (approved_prefixes used only in moduledoc – all other cards approve by default)
  @decline_prefixes    ["59999900", "49999900"]
  @insuf_prefixes      ["57777700", "47777700"]
  @expired_prefixes    ["56666600", "46666600"]
  @pin_req_prefixes    ["58888800", "48888800"]

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Given a PAN (may contain x masking), amount and currency, returns:
    {:approved,      response_code, message}
    {:declined,      response_code, message}
    {:pin_required,  nil,           nil}
  """
  def determine_outcome(pan, amount, _currency) do
    clean = clean_pan(pan)

    cond do
      prefix_match?(clean, @pin_req_prefixes)   -> {:pin_required, nil, nil}
      prefix_match?(clean, @decline_prefixes)   -> {:declined, "05", "Do Not Honour"}
      prefix_match?(clean, @insuf_prefixes)     -> {:declined, "51", "Insufficient Funds"}
      prefix_match?(clean, @expired_prefixes)   -> {:declined, "54", "Expired Card"}
      amount_exceeds?(amount, 99_999)           -> {:declined, "61", "Exceeds Withdrawal Limit"}
      true                                      -> {:approved, "00", "Approved"}
    end
  end

  @doc "Detect card scheme from PAN."
  def detect_scheme(pan) do
    clean = clean_pan(pan)

    cond do
      String.starts_with?(clean, ["51", "52", "53", "54", "55"])  -> "MASTERCARD"
      Regex.match?(~r/^2[2-7]/, clean)                            -> "MASTERCARD"
      String.starts_with?(clean, "4")                             -> "VISA"
      String.starts_with?(clean, ["34", "37"])                    -> "AMEX"
      String.starts_with?(clean, ["60", "65"])                    -> "DISCOVER"
      true                                                        -> "UNKNOWN"
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp clean_pan(nil), do: ""
  defp clean_pan(pan), do: String.replace(pan, ~r/[^0-9]/, "")

  # Match against the first 6 digits of each prefix entry
  defp prefix_match?(pan, prefixes) do
    Enum.any?(prefixes, fn p ->
      String.starts_with?(pan, String.slice(p, 0, 6))
    end)
  end

  defp amount_exceeds?(amount, limit) when is_number(amount), do: amount > limit

  defp amount_exceeds?(amount_str, limit) when is_binary(amount_str) do
    case Float.parse(amount_str) do
      {val, _} -> val > limit
      :error   -> false
    end
  end

  defp amount_exceeds?(_, _), do: false
end
