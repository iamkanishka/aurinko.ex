defmodule Aurinko.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter with per-account and global buckets.

  Each Aurinko access token gets its own bucket so one heavy account
  cannot starve others. A global bucket caps total outbound RPS.

  ## Configuration

      config :aurinko,
        rate_limiter_enabled: true,
        rate_limit_per_token: 10,    # requests/second per token
        rate_limit_global: 100,      # requests/second total
        rate_limit_burst: 5          # extra burst capacity above the per-second rate

  ## Usage

  Normally consumed automatically by the HTTP client. You can also use
  it directly:

      case Aurinko.RateLimiter.check_rate(token) do
        :ok               -> make_request()
        {:wait, delay_ms} -> Process.sleep(delay_ms); make_request()
        {:error, :rate_limit_exceeded} -> {:error, :too_many_requests}
      end
  """

  use GenServer

  require Logger

  @default_per_token_rps 10
  @default_global_rps 100
  @default_burst 5
  # 5 minutes of inactivity → drop bucket
  @cleanup_after_ms 300_000

  # ── Types ─────────────────────────────────────────────────────────────────────

  @type check_result :: :ok | {:wait, non_neg_integer()} | {:error, :rate_limit_exceeded}

  @type bucket :: %{
          tokens: float(),
          last_refill: integer(),
          rate: float(),
          capacity: float()
        }

  # ── Lifecycle ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # ETS table: key → {tokens, last_refill_monotonic_ms}
    table =
      :ets.new(:aurinko_rate_buckets, [:named_table, :public, :set, write_concurrency: true])

    schedule_cleanup()

    {:ok, %{table: table}}
  end

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Check and consume one token for the given access token.

  Returns:
  - `:ok` — request may proceed immediately
  - `{:wait, ms}` — caller should sleep `ms` milliseconds and retry
  - `{:error, :rate_limit_exceeded}` — bucket exhausted even with waiting (not used in standard config)
  """
  @spec check_rate(String.t()) :: check_result()
  def check_rate(token) when is_binary(token) do
    if enabled?() do
      token_key = {:token, hashed_token(token)}
      global_key = :global

      with :ok <- consume_token(token_key, per_token_rate(), per_token_capacity()),
           :ok <- consume_token(global_key, global_rate(), global_capacity()) do
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Reset all buckets for a specific token (e.g. after a 429 with Retry-After).
  """
  @spec reset_token(String.t()) :: :ok
  def reset_token(token) do
    :ets.delete(:aurinko_rate_buckets, {:token, hashed_token(token)})
    :ok
  end

  @doc "Return current bucket state for a token (for debugging/monitoring)."
  @spec inspect_bucket(String.t()) :: bucket() | nil
  def inspect_bucket(token) do
    key = {:token, hashed_token(token)}

    case :ets.lookup(:aurinko_rate_buckets, key) do
      [{^key, tokens, last_refill}] ->
        rate = per_token_rate()
        refilled = refill(tokens, last_refill, rate, per_token_capacity())
        %{tokens: refilled, last_refill: last_refill, rate: rate, capacity: per_token_capacity()}

      [] ->
        nil
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl true
  def handle_info(:cleanup_buckets, state) do
    cutoff = System.monotonic_time(:millisecond) - @cleanup_after_ms

    :ets.select_delete(:aurinko_rate_buckets, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp consume_token(key, rate, capacity) do
    now = System.monotonic_time(:millisecond)

    {tokens, last_refill} =
      case :ets.lookup(:aurinko_rate_buckets, key) do
        [{^key, t, lr}] -> {t, lr}
        [] -> {capacity, now}
      end

    refilled = refill(tokens, last_refill, rate, capacity)

    if refilled >= 1.0 do
      :ets.insert(:aurinko_rate_buckets, {key, refilled - 1.0, now})
      :ok
    else
      # Calculate how long until we'd have 1 token
      wait_ms = trunc((1.0 - refilled) / rate * 1000) + 1
      {:wait, wait_ms}
    end
  end

  defp refill(tokens, last_refill, rate_per_sec, capacity) do
    now = System.monotonic_time(:millisecond)
    elapsed_sec = (now - last_refill) / 1000.0
    new_tokens = tokens + elapsed_sec * rate_per_sec
    min(new_tokens, capacity)
  end

  defp enabled?, do: Application.get_env(:aurinko, :rate_limiter_enabled, true)

  defp per_token_rate,
    do: Application.get_env(:aurinko, :rate_limit_per_token, @default_per_token_rps) * 1.0

  defp global_rate,
    do: Application.get_env(:aurinko, :rate_limit_global, @default_global_rps) * 1.0

  defp burst,
    do: Application.get_env(:aurinko, :rate_limit_burst, @default_burst)

  defp per_token_capacity, do: per_token_rate() + burst()
  defp global_capacity, do: global_rate() + burst()

  defp hashed_token(token) do
    :crypto.hash(:sha256, token) |> binary_part(0, 8)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_buckets, @cleanup_after_ms)
  end
end
