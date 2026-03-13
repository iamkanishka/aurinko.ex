import Config

# =============================================================================
# Aurinko — Test Configuration  (MIX_ENV=test)
#
# Goal: deterministic, hermetic, fast test suite.
#
# Key choices vs. base config:
#   • Retries disabled     — first-attempt behaviour only; retry tests use
#                            explicit multi-expectation Bypass setups
#   • Rate limiter OFF     — never throttle test calls
#   • Circuit breaker OFF  — tests control failure state directly
#   • Cache enabled        — HTTP caching tests need it on; per-test isolation
#                            uses Cache.flush() or bypass_cache: true
#   • Static credentials   — predictable values; no real HTTP ever fires
#                            (Bypass intercepts all calls)
#   • Logger suppressed    — reduce noise; increase to :debug to diagnose
# =============================================================================

config :aurinko,
  # ---------------------------------------------------------------------------
  # Credentials
  # Static hardcoded values are intentional — no real API calls are made.
  # Bypass intercepts all HTTP before it reaches the network.
  # ---------------------------------------------------------------------------
  client_id: "test_client_id",
  client_secret: "test_client_secret",
  webhook_secret: "test_webhook_secret_hmac_key_32_chars_min",

  # ---------------------------------------------------------------------------
  # API
  # Bypass overrides this per-test via Application.put_env/3 in setup.
  # This value is the fallback for unit tests that don't spin up Bypass.
  # ---------------------------------------------------------------------------
  base_url: "http://localhost:9999",

  # ---------------------------------------------------------------------------
  # HTTP Client
  # Short timeout — fail fast if something hangs in CI.
  # ---------------------------------------------------------------------------
  timeout: 5_000,
  pool_size: 2,

  # ---------------------------------------------------------------------------
  # Retry
  # DISABLED. Tests that exercise retry logic explicitly:
  #   1. Set retry_attempts: 2 in their setup block
  #   2. Create a multi-call Bypass.expect/4 that fails then succeeds
  # ---------------------------------------------------------------------------
  retry_attempts: 0,
  retry_delay: 10,

  # ---------------------------------------------------------------------------
  # Cache
  # ON — needed to test caching behaviour in HTTP.ClientTest.
  # Short TTL so expiry tests run quickly.
  # For isolation: call Cache.flush() in setup, or pass bypass_cache: true.
  # ---------------------------------------------------------------------------
  cache_enabled: true,
  cache_ttl: 5_000,
  cache_max_size: 200,
  cache_cleanup_interval: 60_000,

  # ---------------------------------------------------------------------------
  # Rate Limiter
  # DISABLED globally. RateLimiterTest enables it per-test via put_env.
  # ---------------------------------------------------------------------------
  rate_limiter_enabled: false,
  rate_limit_per_token: 10_000,
  rate_limit_global: 100_000,
  rate_limit_burst: 10_000,

  # ---------------------------------------------------------------------------
  # Circuit Breaker
  # DISABLED globally. CircuitBreakerTest enables it per-test via put_env.
  # Low threshold + short timeout for tests that DO enable it.
  # ---------------------------------------------------------------------------
  circuit_breaker_enabled: false,
  circuit_breaker_threshold: 3,
  circuit_breaker_timeout: 50,

  # ---------------------------------------------------------------------------
  # Telemetry
  # Logger silent — keeps `mix test` output clean.
  # Events still fire. Tests may attach their own handlers with
  #   :telemetry.attach/4 in setup and detach in on_exit.
  # ---------------------------------------------------------------------------
  attach_default_telemetry: false,

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  log_level: :warning

# Logger: warnings and above only. Flip to :debug to diagnose a failing test.
config :logger,
  level: :warning

config :logger, :console, format: "[$level] $message\n"

# ExCoveralls
config :excoveralls,
  output_dir: "cover/",
  minimum_coverage: 80.0
