defmodule Aurinko.Cache do
  @moduledoc """
  ETS-backed in-memory cache with per-entry TTL and LRU eviction.

  Used transparently by the HTTP client for cacheable GET requests.
  Cache is keyed by `{token_hash, path, params}` so different accounts
  never share cached data.

  ## Configuration

      config :aurinko,
        cache_enabled: true,
        cache_ttl: 60_000,          # ms; default 60 seconds
        cache_max_size: 5_000,      # max entries before LRU eviction
        cache_cleanup_interval: 30_000   # ms between sweep runs

  ## Usage

      Aurinko.Cache.get("my_key")         # => nil | {:ok, value}
      Aurinko.Cache.put("my_key", value)
      Aurinko.Cache.put("my_key", value, ttl: 5_000)
      Aurinko.Cache.delete("my_key")
      Aurinko.Cache.invalidate_token(token)   # purge all entries for an account
      Aurinko.Cache.stats()
  """

  use GenServer

  require Logger

  @table :aurinko_cache
  @default_ttl 60_000
  @default_max_size 5_000
  @default_cleanup_interval 30_000

  # ── Types ─────────────────────────────────────────────────────────────────────

  @type cache_key :: String.t()
  @type ttl_ms :: pos_integer()

  @type stats :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          evictions: non_neg_integer(),
          size: non_neg_integer()
        }

  # ── Lifecycle ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    cleanup_interval =
      Keyword.get(opts, :cleanup_interval) ||
        Application.get_env(:aurinko, :cache_cleanup_interval, @default_cleanup_interval)

    schedule_cleanup(cleanup_interval)

    state = %{
      table: table,
      cleanup_interval: cleanup_interval,
      hits: :counters.new(1, [:atomics]),
      misses: :counters.new(1, [:atomics]),
      evictions: :counters.new(1, [:atomics])
    }

    {:ok, state}
  end

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Retrieve a value from the cache.

  Returns `{:ok, value}` on a hit, `nil` on a miss or expired entry.
  """
  @spec get(cache_key()) :: {:ok, term()} | nil
  def get(key) when is_binary(key) do
    if enabled?(), do: lookup_entry(key), else: nil
  end

  defp lookup_entry(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _inserted_at}] ->
        check_expiry(key, value, expires_at)

      [] ->
        bump_stat(:misses)
        nil
    end
  end

  defp check_expiry(key, value, expires_at) do
    if System.monotonic_time(:millisecond) < expires_at do
      bump_stat(:hits)
      {:ok, value}
    else
      :ets.delete(@table, key)
      bump_stat(:misses)
      nil
    end
  end

  @doc """
  Store a value in the cache.

  ## Options

  - `:ttl` — Time-to-live in milliseconds. Defaults to configured `cache_ttl`.
  """
  @spec put(cache_key(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) when is_binary(key) do
    if enabled?() do
      ttl = Keyword.get(opts, :ttl, configured_ttl())
      now = System.monotonic_time(:millisecond)
      expires_at = now + ttl

      max_size = configured_max_size()
      current_size = :ets.info(@table, :size)

      if current_size >= max_size do
        evict_lru(max_size)
      end

      :ets.insert(@table, {key, value, expires_at, now})
      :ok
    else
      :ok
    end
  end

  @doc "Delete a single cache entry."
  @spec delete(cache_key()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Invalidate all cache entries associated with a specific token.

  Call this after a token is refreshed or revoked.
  """
  @spec invalidate_token(String.t()) :: :ok
  def invalidate_token(token) when is_binary(token) do
    prefix = token_prefix(token)

    :ets.match_object(@table, {:"$1", :_, :_, :_})
    |> Enum.each(fn {key, _, _, _} ->
      if String.starts_with?(key, prefix), do: :ets.delete(@table, key)
    end)

    :ok
  end

  @doc "Clear the entire cache."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Return cache hit/miss/eviction statistics."
  @spec stats() :: stats()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Build a deterministic cache key from token + path + params."
  @spec build_key(String.t(), String.t(), keyword() | map()) :: cache_key()
  def build_key(token, path, params \\ []) do
    prefix = token_prefix(token)
    params_hash = :erlang.phash2(params)
    "#{prefix}:#{path}:#{params_hash}"
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      hits: :counters.get(state.hits, 1),
      misses: :counters.get(state.misses, 1),
      evictions: :counters.get(state.evictions, 1),
      size: :ets.info(@table, :size)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_counter, :hits}, _from, state), do: {:reply, state.hits, state}
  def handle_call({:get_counter, :misses}, _from, state), do: {:reply, state.misses, state}
  def handle_call({:get_counter, :evictions}, _from, state), do: {:reply, state.evictions, state}

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    expired_count = cleanup_expired(now)

    if expired_count > 0 do
      Logger.debug("[Aurinko.Cache] Swept #{expired_count} expired entries")
    end

    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp enabled?, do: Application.get_env(:aurinko, :cache_enabled, true)
  defp configured_ttl, do: Application.get_env(:aurinko, :cache_ttl, @default_ttl)

  defp configured_max_size,
    do: Application.get_env(:aurinko, :cache_max_size, @default_max_size)

  defp token_prefix(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_expired(now) do
    # Select all expired entries and delete them
    expired =
      :ets.select(@table, [
        {{:"$1", :_, :"$2", :_}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  defp evict_lru(max_size) do
    # Evict the oldest 10% of entries
    evict_count = max(1, div(max_size, 10))

    :ets.select(@table, [{{:"$1", :_, :_, :"$4"}, [], [{{:"$4", :"$1"}}]}])
    |> Enum.sort()
    |> Enum.take(evict_count)
    |> Enum.each(fn {_ts, key} ->
      :ets.delete(@table, key)
      bump_stat(:evictions)
    end)
  end

  defp bump_stat(counter) do
    state = GenServer.call(__MODULE__, {:get_counter, counter}, 50)
    :counters.add(state, 1, 1)
  catch
    _, _ -> :ok
  end
end
