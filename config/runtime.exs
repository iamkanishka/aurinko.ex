import Config

# =============================================================================
# Aurinko — Runtime Configuration
#
# Evaluated at RUNTIME by Config.Provider (releases) or mix run (non-releases).
# This is the ONLY place where secrets and environment-specific values are
# read from the system environment.
#
# Execution order:
#   config.exs  (compile-time defaults)
#   {env}.exs   (compile-time env overlay)
#   runtime.exs (runtime — THIS FILE — always last, always wins)
#
# Design rules:
#   1. Required secrets use System.fetch_env!/1  → crash at startup if absent
#      rather than at call time with a cryptic error.
#   2. Optional tunables use System.get_env/2    → fall back to env defaults.
#   3. All parsed values are validated before assignment.
#   4. In :dev/:test, credentials fall back to placeholder strings so
#      developers can start the app without a real Aurinko account.
#   5. Never set a value in runtime.exs that never needs to change at runtime.
#
# ─────────────────────────────────────────────────────────────────────────────
# Required environment variables  (prod + staging)
# ─────────────────────────────────────────────────────────────────────────────
#   AURINKO_CLIENT_ID       Aurinko application OAuth client ID
#   AURINKO_CLIENT_SECRET   Aurinko application OAuth client secret
#
# ─────────────────────────────────────────────────────────────────────────────
# Recommended environment variables
# ─────────────────────────────────────────────────────────────────────────────
#   AURINKO_WEBHOOK_SECRET  HMAC-SHA256 key for webhook signature verification.
#                           Without this, all inbound webhooks fail verification.
#
# ─────────────────────────────────────────────────────────────────────────────
# Optional environment variables  (all environments)
# ─────────────────────────────────────────────────────────────────────────────
#   AURINKO_BASE_URL             Override API base URL       (default: https://api.aurinko.io/v1)
#   AURINKO_TIMEOUT_MS           HTTP receive timeout ms     (default: 30_000)
#   AURINKO_POOL_SIZE            Connection pool size        (default: 20)
#   AURINKO_RETRY_ATTEMPTS       Max retry attempts          (default: 3)
#   AURINKO_RETRY_DELAY_MS       Base retry delay ms         (default: 500)
#   AURINKO_CACHE_ENABLED        "true" | "false"            (default: true)
#   AURINKO_CACHE_TTL_MS         Cache TTL ms                (default: 300_000)
#   AURINKO_CACHE_MAX_SIZE       Max ETS entries             (default: 10_000)
#   AURINKO_CACHE_CLEANUP_MS     Sweep interval ms           (default: 60_000)
#   AURINKO_RATE_LIMITER_ENABLED "true" | "false"            (default: true)
#   AURINKO_RATE_PER_TOKEN       Req/s per token             (default: 10)
#   AURINKO_RATE_GLOBAL          Req/s global cap            (default: 100)
#   AURINKO_RATE_BURST           Burst headroom              (default: 5)
#   AURINKO_CB_ENABLED           "true" | "false"            (default: true)
#   AURINKO_CB_THRESHOLD         CB failure threshold        (default: 5)
#   AURINKO_CB_TIMEOUT_MS        CB open duration ms         (default: 30_000)
#   AURINKO_LOG_LEVEL            debug|info|warning|error    (default: info)
# =============================================================================

# ── Parsing helpers ────────────────────────────────────────────────────────────
# Defined as module-level functions so they can be reused and tested.
# Using anonymous functions (not defp) because this file is evaled, not compiled.

parse_int! = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "" ->
      default

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 ->
          n

        _ ->
          raise RuntimeError,
                "Environment variable #{name} must be a positive integer. Got: #{inspect(raw)}"
      end
  end
end

parse_bool! = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "true" ->
      true

    "1" ->
      true

    "false" ->
      false

    "0" ->
      false

    raw ->
      raise RuntimeError,
            "Environment variable #{name} must be \"true\" or \"false\". Got: #{inspect(raw)}"
  end
end

parse_log_level! = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "debug" ->
      :debug

    "info" ->
      :info

    "warning" ->
      :warning

    "warn" ->
      :warning

    "error" ->
      :error

    raw ->
      raise RuntimeError,
            "Environment variable #{name} must be one of: debug, info, warning, error. " <>
              "Got: #{inspect(raw)}"
  end
end

# ── Credential loading ─────────────────────────────────────────────────────────

# prod and staging: crash at startup if credentials are missing.
# dev and test: accept placeholders — the app will start but API calls will fail
# with 401 until real credentials are provided.
{client_id, client_secret} =
  if config_env() in [:prod, :staging] do
    id = System.fetch_env!("AURINKO_CLIENT_ID")
    secret = System.fetch_env!("AURINKO_CLIENT_SECRET")

    # Belt-and-suspenders: catch accidentally blank values
    if String.trim(id) == "" do
      raise "AURINKO_CLIENT_ID is set but blank. Provide a valid client ID."
    end

    if String.trim(secret) == "" do
      raise "AURINKO_CLIENT_SECRET is set but blank. Provide a valid client secret."
    end

    {id, secret}
  else
    {
      System.get_env("AURINKO_CLIENT_ID", "dev_placeholder_client_id"),
      System.get_env("AURINKO_CLIENT_SECRET", "dev_placeholder_client_secret")
    }
  end

# Webhook secret: optional across all environments.
# In prod, absence is a warning (not a crash) because not every deployment
# uses webhooks. The library will refuse to verify signatures if this is nil.
webhook_secret = System.get_env("AURINKO_WEBHOOK_SECRET")

if config_env() == :prod && is_nil(webhook_secret) do
  IO.warn("""
  [Aurinko] AURINKO_WEBHOOK_SECRET is not set.
  All inbound webhook signature verifications will fail with {:error, :invalid_signature}.
  If your application receives Aurinko webhooks, set this to your webhook signing secret.
  """)
end

# ── Resolved log level ─────────────────────────────────────────────────────────

log_level = parse_log_level!.("AURINKO_LOG_LEVEL", :info)

# ── Apply runtime config ───────────────────────────────────────────────────────

config :aurinko,
  # Credentials
  client_id: client_id,
  client_secret: client_secret,
  webhook_secret: webhook_secret,

  # API — allow redirecting to a mock server without rebuilding the release
  base_url:
    System.get_env("AURINKO_BASE_URL", "https://api.aurinko.io/v1")
    |> String.trim_trailing("/"),

  # HTTP Client
  timeout: parse_int!.("AURINKO_TIMEOUT_MS", 30_000),
  pool_size: parse_int!.("AURINKO_POOL_SIZE", 20),

  # Retry
  retry_attempts: parse_int!.("AURINKO_RETRY_ATTEMPTS", 3),
  retry_delay: parse_int!.("AURINKO_RETRY_DELAY_MS", 500),

  # Cache
  cache_enabled: parse_bool!.("AURINKO_CACHE_ENABLED", true),
  cache_ttl: parse_int!.("AURINKO_CACHE_TTL_MS", 300_000),
  cache_max_size: parse_int!.("AURINKO_CACHE_MAX_SIZE", 10_000),
  cache_cleanup_interval: parse_int!.("AURINKO_CACHE_CLEANUP_MS", 60_000),

  # Rate Limiter
  rate_limiter_enabled: parse_bool!.("AURINKO_RATE_LIMITER_ENABLED", true),
  rate_limit_per_token: parse_int!.("AURINKO_RATE_PER_TOKEN", 10),
  rate_limit_global: parse_int!.("AURINKO_RATE_GLOBAL", 100),
  rate_limit_burst: parse_int!.("AURINKO_RATE_BURST", 5),

  # Circuit Breaker
  circuit_breaker_enabled: parse_bool!.("AURINKO_CB_ENABLED", true),
  circuit_breaker_threshold: parse_int!.("AURINKO_CB_THRESHOLD", 5),
  circuit_breaker_timeout: parse_int!.("AURINKO_CB_TIMEOUT_MS", 30_000),

  # Logging
  log_level: log_level

# Sync the Elixir Logger level with our configured log_level so they never
# diverge (e.g. Logger suppressing messages the lib thinks it's sending).
config :logger,
  level: log_level
