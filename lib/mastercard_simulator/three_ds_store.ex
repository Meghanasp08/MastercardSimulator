defmodule MastercardSimulator.ThreeDSStore do
  @moduledoc """
  ETS-backed in-memory store for pending 3-D Secure state:

    "challenge:" <> id  – 3DS1 ACS round-trip (order/txn context, TermUrl, MD)
    "auth:"      <> id  – 3DS2 hosted-session challenge (response_url)
    "session:"   <> id  – session-level 3DS2 context (response_url) recorded
                          when the session is created/updated

  Keyed by an opaque string id (namespaced by prefix above) so all three
  kinds of pending state can share one table.
  """
  use GenServer
  require Logger

  @table :mpgs_sim_3ds

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Store (overwriting) the value for a key."
  def put(key, data) do
    :ets.insert(@table, {key, data})
    :ok
  end

  @doc "Shallow-merge `changes` into whatever is currently stored at `key`."
  def merge(key, changes) do
    current =
      case get(key) do
        {:ok, data} -> data
        {:error, :not_found} -> %{}
      end

    put(key, Map.merge(current, changes))
  end

  @doc "Fetch the value stored at `key`."
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[ThreeDSStore] ETS table '#{@table}' initialised")
    {:ok, %{}}
  end
end
