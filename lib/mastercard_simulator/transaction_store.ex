defmodule MastercardSimulator.TransactionStore do
  @moduledoc """
  ETS-backed in-memory store for simulated transactions.
  Keyed by {order_id, transaction_id}.
  """
  use GenServer
  require Logger

  @table :mpgs_sim_transactions

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Persist (or overwrite) a transaction record."
  def put(order_id, transaction_id, data) do
    :ets.insert(@table, {{order_id, transaction_id}, data})
    :ok
  end

  @doc "Fetch a single transaction by order + transaction ID."
  def get(order_id, transaction_id) do
    case :ets.lookup(@table, {order_id, transaction_id}) do
      [{{^order_id, ^transaction_id}, data}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @doc "Return all transactions belonging to a given order."
  def get_by_order(order_id) do
    :ets.match_object(@table, {{order_id, :_}, :_})
    |> Enum.map(fn {_key, data} -> data end)
  end

  @doc "Return every stored transaction (for admin/debug)."
  def all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, data} -> data end)
    |> Enum.sort_by(& &1.stored_at, {:desc, DateTime})
  end

  @doc "Wipe all stored transactions (test helper)."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[TransactionStore] ETS table '#{@table}' initialised")
    {:ok, %{}}
  end
end
