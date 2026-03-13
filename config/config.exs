import Config

# =============================================================================
# Aurinko — Base Configuration
#
# Loaded in EVERY environment before the environment-specific overlay.
# Sets the canonical defaults for every config key the library reads.
# Environment files override only what differs. Secrets never live here.
#
# Config layer order (last write wins):
#   1. config/config.exs        ← you are here (defaults)
#   2. config/{env}.exs         ← environment overlay  (dev / test / staging / prod)
#   3. config/runtime.exs       ← runtime secrets & env-var overrides
# =============================================================================

config :aurinko,
  # ---------------------------------------------------------------------------
  # Credentials
  # Set to nil here. runtime.exs MUST supply real values at startup.
  # The library raises Aurinko.ConfigError if these are still nil at runtime.
  # ---------------------------------------------------------------------------
  client_id: nil,
  client_secret: nil,
  webhook_secret: nil,

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------
  base_url: "https://api.aurinko.io/v1",

  # ---------------------------------------------------------------------------
  # HTTP Client
  #
  # timeout     — receive_timeout on the underlying Req client; does not
  #               include connection establishment (fixed at 5_000ms).
  # pool_size   — concurrent connections per host via Finch/Mint.
  # ---------------------------------------------------------------------------
  timeout: 30_000,
  pool_size: 10,

  # ---------------------------------------------------------------------------
  # Retry
  #
  # Applied on 429 (rate-limited) and 5xx (server error) responses.
  # Delay formula: retry_delay * 2^attempt + rand(0..200)ms
  #
  # retry_attempts: 3 with retry_delay: 500ms
  #   → worst-case budget ≈ 500 + 1_000 + 2_000 + jitter ≈ 3.7 s
  # ---------------------------------------------------------------------------
  retry_attempts: 3,
  retry_delay: 500,

  # ---------------------------------------------------------------------------
  # Cache (ETS-backed, per-token namespaced)
  #
  # cache_ttl         — default TTL for all GET responses (ms).
  #                     Override per-request: get(token, path, cache_ttl: 5_000)
  # cache_max_size    — max ETS entry count before LRU-style eviction.
  #                     Rough sizing: unique_accounts × distinct_endpoints.
  #                     At ~1 KB per entry, 5_000 entries ≈ 5 MB.
  # cache_cleanup_interval — background sweep cadence (ms).
  # ---------------------------------------------------------------------------
  cache_enabled: true,
  cache_ttl: 60_000,
  cache_max_size: 5_000,
  cache_cleanup_interval: 30_000,

  # ---------------------------------------------------------------------------
  # Rate Limiter (token-bucket, per-token + global)
  #
  # rate_limit_per_token — sustained req/s allowed per Aurinko access token.
  # rate_limit_global    — total req/s cap across ALL tokens.
  # rate_limit_burst     — extra tokens available above the sustained rate.
  #                        Effective per-token capacity =
  #                          rate_limit_per_token + rate_limit_burst
  # ---------------------------------------------------------------------------
  rate_limiter_enabled: true,
  rate_limit_per_token: 10,
  rate_limit_global: 100,
  rate_limit_burst: 5,

  # ---------------------------------------------------------------------------
  # Circuit Breaker (closed → open → half-open per endpoint)
  #
  # circuit_breaker_threshold — consecutive server/network errors before opening.
  # circuit_breaker_timeout   — ms in OPEN state before probing (half-open).
  #                             On probe success  → CLOSED (failure_count reset)
  #                             On probe failure  → OPEN   (timeout resets)
  # ---------------------------------------------------------------------------
  circuit_breaker_enabled: true,
  circuit_breaker_threshold: 5,
  circuit_breaker_timeout: 30_000,

  # ---------------------------------------------------------------------------
  # Telemetry
  #
  # attach_default_telemetry — when true, Aurinko.Telemetry attaches a
  # structured Logger handler for all events on application start.
  # Useful in dev/staging; in prod use a proper reporter (Prometheus, StatsD).
  # ---------------------------------------------------------------------------
  attach_default_telemetry: false,

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  log_level: :info

# Load the environment-specific overlay.
# NOTE: :staging is not a built-in Mix env. To use it:
#   MIX_ENV=staging mix run / mix release
# The import below works for :dev, :test, :staging, :prod.
import_config "#{config_env()}.exs"
