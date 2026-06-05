defmodule MastercardSimulator do
  @moduledoc """
  Mastercard Gateway (MPGS) Simulator.

  A lightweight Plug-based HTTP server that mimics the Mastercard Payment Gateway
  REST API (v77) for card-present transactions. Used by the Mercury Device
  Middlelayer for local development and integration testing without hitting
  the live MPGS environment.

  ## Starting

      cd mastercardSimulator
      mix deps.get
      mix run --no-halt              # default port 4001
      PORT=4002 mix run --no-halt    # custom port

  ## API Base URL

      http://localhost:4001/api/rest/version/77

  ## Authentication

      HTTP Basic Auth
      Username: merchant.TEST_MERCHANT
      Password: test_password_123

  ## Test Card Matrix

      5123 45xx xxxx xxxx  → Mastercard, Approved
      4111 11xx xxxx xxxx  → Visa,        Approved
      3782 82xx xxxx xxxx  → Amex,        Approved
      5999 99xx xxxx xxxx  → Mastercard,  Declined (05)
      4999 99xx xxxx xxxx  → Visa,        Declined (05)
      5777 77xx xxxx xxxx  → Mastercard,  Declined (51 Insufficient Funds)
      5666 66xx xxxx xxxx  → Mastercard,  Declined (54 Expired)
      5888 88xx xxxx xxxx  → Mastercard,  PIN Required (single-tap flow)
      4888 88xx xxxx xxxx  → Visa,        PIN Required (single-tap flow)
      Any amount > 99,999  → any scheme,  Declined (61 Exceeds Limit)
  """
end
