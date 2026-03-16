defmodule Aurinko.Application do
  @moduledoc """
  OTP Application entry point for Aurinko.

  Starts and supervises all library processes in dependency order:

  ```
  Aurinko.Supervisor (one_for_one)
  ├── Aurinko.Cache           ETS-backed TTL response cache
  ├── Aurinko.RateLimiter     Token-bucket rate limiter (per-token + global)
  ├── Aurinko.CircuitBreaker  Per-endpoint circuit breaker state machine
  ├── Client     Req-based HTTP client (depends on above three)
  └── Aurinko.Telemetry       Telemetry event handler / reporter setup
  ```

  ## Startup sequence

  1. Validate config (fail fast with a clear error if credentials are missing).
  2. Start ETS-owning GenServers (Cache, RateLimiter, CircuitBreaker) first.
  3. Start the HTTP client, which reads config and builds the Req base request.
  4. Start Telemetry and optionally attach the default Logger handler.
  5. Log a structured startup summary.

  ## Shutdown

  OTP sends `:shutdown` to children in reverse start order (Telemetry → HTTP
  Client → CircuitBreaker → RateLimiter → Cache). Each GenServer has a 5 s
  shutdown timeout to flush in-flight state. The ETS tables owned by Cache,
  RateLimiter, and CircuitBreaker are automatically deleted when their owning
  process exits.
  """

  use Application

  require Logger

  alias Aurinko.HTTP.Client

  @shutdown_timeout 5_000

  @impl true
  def start(_type, _args) do
    # ── 1. Validate configuration before starting any child ──────────────────
    # Fail loudly at startup with a clear error rather than at call time with
    # a confusing nil credential or missing key error.
    validate_config!()

    # ── 2. Build supervision tree ────────────────────────────────────────────
    children = [
      # ETS cache — must start before the HTTP client which may write to it
      %{
        id: Aurinko.Cache,
        start: {Aurinko.Cache, :start_link, [[]]},
        restart: :permanent,
        shutdown: @shutdown_timeout,
        type: :worker
      },

      # Rate limiter — must start before the HTTP client which checks it
      %{
        id: Aurinko.RateLimiter,
        start: {Aurinko.RateLimiter, :start_link, [[]]},
        restart: :permanent,
        shutdown: @shutdown_timeout,
        type: :worker
      },

      # Circuit breaker — must start before the HTTP client which calls it
      %{
        id: Aurinko.CircuitBreaker,
        start: {Aurinko.CircuitBreaker, :start_link, [[]]},
        restart: :permanent,
        shutdown: @shutdown_timeout,
        type: :worker
      },

      # HTTP client — depends on Cache, RateLimiter, CircuitBreaker being up
      %{
        id: Client,
        start: {Client, :start_link, [[]]},
        restart: :permanent,
        shutdown: @shutdown_timeout,
        type: :worker
      },

      # Telemetry — last; no other child depends on it
      %{
        id: Aurinko.Telemetry,
        start:
          {Aurinko.Telemetry, :start_link,
           [
             [
               attach_default_logger:
                 Application.get_env(:aurinko, :attach_default_telemetry, false)
             ]
           ]},
        restart: :permanent,
        shutdown: @shutdown_timeout,
        type: :worker
      }
    ]

    opts = [strategy: :one_for_one, name: Aurinko.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        log_startup_summary()
        {:ok, pid}

      {:error, reason} = err ->
        Logger.error("[Aurinko] Supervisor failed to start: #{inspect(reason)}")
        err
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("[Aurinko] Application stopping — flushing resources")
    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Validate all required and typed configuration keys before any child starts.
  # Raises Aurinko.ConfigError with a descriptive message on failure.
  defp validate_config! do
    env = Application.get_all_env(:aurinko)

    errors =
      []
      |> check_required(env, :client_id, "AURINKO_CLIENT_ID")
      |> check_required(env, :client_secret, "AURINKO_CLIENT_SECRET")
      |> check_pos_integer(env, :timeout, "AURINKO_TIMEOUT_MS")
      |> check_pos_integer(env, :pool_size, "AURINKO_POOL_SIZE")
      |> check_non_neg_integer(env, :retry_attempts, "AURINKO_RETRY_ATTEMPTS")
      |> check_pos_integer(env, :retry_delay, "AURINKO_RETRY_DELAY_MS")
      |> check_pos_integer(env, :cache_ttl, "AURINKO_CACHE_TTL_MS")
      |> check_pos_integer(env, :cache_max_size, "AURINKO_CACHE_MAX_SIZE")
      |> check_pos_integer(env, :rate_limit_per_token, "AURINKO_RATE_PER_TOKEN")
      |> check_pos_integer(env, :rate_limit_global, "AURINKO_RATE_GLOBAL")
      |> check_pos_integer(env, :circuit_breaker_threshold, "AURINKO_CB_THRESHOLD")
      |> check_pos_integer(env, :circuit_breaker_timeout, "AURINKO_CB_TIMEOUT_MS")

    if errors != [] do
      message = Enum.join(errors, "\n  ")

      raise Aurinko.ConfigError, """
      Aurinko failed to start due to invalid or missing configuration:

      #{message}

      Fix these issues in your config/runtime.exs or set the corresponding
      environment variables. See config/.env.example for the full variable list.
      """
    end
  end

  defp check_required(errors, env, key, env_var) do
    value = Keyword.get(env, key)

    cond do
      is_nil(value) ->
        ["#{key}: required but not set. Set #{env_var} environment variable." | errors]

      is_binary(value) && String.trim(value) == "" ->
        ["#{key}: must not be blank. #{env_var} is set to an empty string." | errors]

      true ->
        errors
    end
  end

  defp check_pos_integer(errors, env, key, env_var) do
    case Keyword.get(env, key) do
      nil ->
        errors

      n when is_integer(n) and n > 0 ->
        errors

      bad ->
        ["#{key}: must be a positive integer (got #{inspect(bad)}). Check #{env_var}." | errors]
    end
  end

  defp check_non_neg_integer(errors, env, key, env_var) do
    case Keyword.get(env, key) do
      nil ->
        errors

      n when is_integer(n) and n >= 0 ->
        errors

      bad ->
        [
          "#{key}: must be a non-negative integer (got #{inspect(bad)}). Check #{env_var}."
          | errors
        ]
    end
  end

  defp log_startup_summary do
    env = Application.get_all_env(:aurinko)

    Logger.info("""
    [Aurinko] Started successfully
      version:            #{Application.spec(:aurinko, :vsn) || "dev"}
      base_url:           #{Keyword.get(env, :base_url)}
      timeout:            #{Keyword.get(env, :timeout)}ms
      pool_size:          #{Keyword.get(env, :pool_size)}
      retry_attempts:     #{Keyword.get(env, :retry_attempts)}
      cache_enabled:      #{Keyword.get(env, :cache_enabled)}
      cache_ttl:          #{Keyword.get(env, :cache_ttl)}ms
      cache_max_size:     #{Keyword.get(env, :cache_max_size)}
      rate_limiter:       #{Keyword.get(env, :rate_limiter_enabled)} \
    (#{Keyword.get(env, :rate_limit_per_token)} req/s per token, \
    #{Keyword.get(env, :rate_limit_global)} global)
      circuit_breaker:    #{Keyword.get(env, :circuit_breaker_enabled)} \
    (threshold: #{Keyword.get(env, :circuit_breaker_threshold)}, \
    timeout: #{Keyword.get(env, :circuit_breaker_timeout)}ms)
      webhook_secret:     #{if Keyword.get(env, :webhook_secret), do: "[set]", else: "[NOT SET]"}
      telemetry_logger:   #{Keyword.get(env, :attach_default_telemetry)}
    """)
  end
end
