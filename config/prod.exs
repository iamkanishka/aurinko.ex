import Config

# =============================================================================
# Aurinko — Production Configuration  (MIX_ENV=prod)
#
# Goals: reliability, throughput, efficient quota usage, structured observability.
#
# Rules enforced here:
#   1. Zero secrets — all credentials and tokens live in runtime.exs
#   2. Fail fast    — if required config is absent, crash at startup
#   3. Cache hard   — reduce API quota consumption with a long TTL
#   4. Retry gently — don't amplify load on a degraded Aurinko endpoint
#   5. Circuit break firmly — protect your app from cascading failures
#   6. No default telemetry logger — use a proper metrics reporter
#   7. Structured JSON logging — for log aggregation pipelines
#
# IMPORTANT: This file is committed to source control.
#            It MUST NOT contain any secrets or deployment-specific URLs.
# =============================================================================

config :aurinko,
  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------
  base_url: "https://api.aurinko.io/v1",

  # ---------------------------------------------------------------------------
  # HTTP Client
  #
  # timeout: 30 s covers Aurinko's sync initialisation responses, which are
  # occasionally slow on first call. Narrow this per-request for fast endpoints.
  #
  # pool_size: start at 20 and tune upward using telemetry data.
  # Rule of thumb: ceil(peak_rps * p99_latency_s)
  # ---------------------------------------------------------------------------
  timeout: 30_000,
  pool_size: 20,

  # ---------------------------------------------------------------------------
  # Retry
  #
  # 3 attempts, 500 ms base → worst-case extra latency ≈ 3.7 s per request.
  # This absorbs transient 5xx/429 spikes without masking real degradation
  # (the circuit breaker handles that).
  # ---------------------------------------------------------------------------
  retry_attempts: 3,
  retry_delay: 500,

  # ---------------------------------------------------------------------------
  # Cache
  #
  # 5-minute TTL covers resources that change infrequently (calendar list,
  # contact list, booking profiles). For volatile data (unread message counts,
  # live events), callers should pass:
  #   cache_ttl: 30_000        — shorter TTL
  #   bypass_cache: true       — skip cache entirely
  #
  # cache_max_size sizing:
  #   unique_accounts × distinct_endpoints_per_account × safety_factor
  #   Example: 500 accounts × 8 endpoints × 2.5 = 10_000
  #   At ~1 KB/entry → ~10 MB ETS overhead.
  # ---------------------------------------------------------------------------
  cache_enabled: true,
  cache_ttl: 300_000,
  cache_max_size: 10_000,
  cache_cleanup_interval: 60_000,

  # ---------------------------------------------------------------------------
  # Rate Limiter
  #
  # Defaults match Aurinko's published limits for production applications.
  # Tune rate_limit_global upward if your Aurinko plan permits higher throughput.
  # Reference: https://docs.aurinko.io/authentication/authentication-scopes
  # ---------------------------------------------------------------------------
  rate_limiter_enabled: true,
  rate_limit_per_token: 10,
  rate_limit_global: 100,
  rate_limit_burst: 5,

  # ---------------------------------------------------------------------------
  # Circuit Breaker
  #
  # Opens after 5 consecutive server/network errors per normalised endpoint.
  # Stays open for 30 s, then sends one probe. On success → closed.
  # Prevents retry storms from amplifying a degraded Aurinko endpoint.
  # ---------------------------------------------------------------------------
  circuit_breaker_enabled: true,
  circuit_breaker_threshold: 5,
  circuit_breaker_timeout: 30_000,

  # ---------------------------------------------------------------------------
  # Telemetry
  #
  # DO NOT set true in prod — the default Logger handler is too chatty.
  #
  # Instead, plug Aurinko.Telemetry.metrics() into your app's reporter:
  #
  #   # lib/my_app/telemetry.ex
  #   def metrics do
  #     [
  #       ...your_existing_metrics...,
  #       Aurinko.Telemetry.metrics()
  #     ]
  #     |> List.flatten()
  #   end
  # ---------------------------------------------------------------------------
  attach_default_telemetry: false,

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  log_level: :info

# ---------------------------------------------------------------------------
# Logger — structured JSON for aggregation pipelines
#
# Replace {Aurinko.Logger.JSONFormatter, :format} with your own formatter
# if you use LoggerJSON, Ink, or another library.
# ---------------------------------------------------------------------------
config :logger,
  level: :info,
  handle_otp_reports: true,
  handle_sasl_reports: false

config :logger, :console,
  format: {Aurinko.Logger.JSONFormatter, :format},
  metadata: [:request_id, :module, :function, :line, :pid]
