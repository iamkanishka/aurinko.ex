import Config

# =============================================================================
# Aurinko — Staging Configuration  (MIX_ENV=staging)
#
# NOTE: :staging is not a built-in Mix env. You must build releases with:
#   MIX_ENV=staging mix release
#
# Goal: production parity with slightly looser observability settings so
# engineers can validate deployments before they reach prod.
#
# Intentional differences from prod:
#   • Lower rate limits      — staging Aurinko app has a sandbox quota
#   • Lower CB threshold     — surface instability earlier in pre-prod
#   • Shorter CB timeout     — faster recovery during QA cycles
#   • Shorter cache TTL      — see fresher data; easier to validate
#   • Telemetry logger ON    — tail logs directly when debugging staging issues
#   • Verbose logging        — :info (prod is also :info, but staging logger
#                              includes more metadata fields)
#
# Credentials and secrets → runtime.exs only. Nothing sensitive here.
#
# Required env vars on the staging host:
#   AURINKO_CLIENT_ID       staging Aurinko application client ID
#   AURINKO_CLIENT_SECRET   staging Aurinko application client secret
#   AURINKO_WEBHOOK_SECRET  staging webhook signing secret
# =============================================================================

config :aurinko,
  # ---------------------------------------------------------------------------
  # API
  # Same production endpoint — staging apps use different credentials, not a
  # different API host.
  # ---------------------------------------------------------------------------
  base_url: "https://api.aurinko.io/v1",

  # ---------------------------------------------------------------------------
  # HTTP Client
  # Match production timeouts exactly for realistic latency testing.
  # ---------------------------------------------------------------------------
  timeout: 30_000,
  pool_size: 10,

  # ---------------------------------------------------------------------------
  # Retry
  # Slightly faster base delay than prod so staging test cycles are quicker,
  # but same attempt count to validate retry logic end-to-end.
  # ---------------------------------------------------------------------------
  retry_attempts: 3,
  retry_delay: 300,

  # ---------------------------------------------------------------------------
  # Cache
  # Shorter TTL than prod to make it easier to validate live API changes
  # during QA without needing to flush manually.
  # ---------------------------------------------------------------------------
  cache_enabled: true,
  cache_ttl: 60_000,
  cache_max_size: 2_000,
  cache_cleanup_interval: 30_000,

  # ---------------------------------------------------------------------------
  # Rate Limiter
  # Aurinko sandbox accounts have lower API quotas than production.
  # These values must match the limits on the staging Aurinko application.
  # Check: https://aurinko.io portal → Your App → API Limits
  # ---------------------------------------------------------------------------
  rate_limiter_enabled: true,
  rate_limit_per_token: 5,
  rate_limit_global: 50,
  rate_limit_burst: 3,

  # ---------------------------------------------------------------------------
  # Circuit Breaker
  # Lower threshold (4 vs 5) and shorter timeout (15 s vs 30 s) than prod.
  # Surfaces instability during pre-production validation faster.
  # ---------------------------------------------------------------------------
  circuit_breaker_enabled: true,
  circuit_breaker_threshold: 4,
  circuit_breaker_timeout: 15_000,

  # ---------------------------------------------------------------------------
  # Telemetry
  # Logger attached in staging for real-time request tracing.
  # Disable and switch to a Prometheus reporter if you run load tests.
  # ---------------------------------------------------------------------------
  attach_default_telemetry: true,

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  log_level: :info

# Logger: structured JSON to stdout for log aggregation (Datadog, Loki, etc.)
# On staging we include extra metadata fields vs. prod for easier debugging.
config :logger,
  level: :info

config :logger, :console,
  format: {Aurinko.Logger.JSONFormatter, :format},
  metadata: [:request_id, :module, :function, :line, :pid]
