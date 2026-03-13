import Config

# =============================================================================
# Aurinko — Development Configuration  (MIX_ENV=dev)
#
# Goal: rapid feedback loops during local development.
#
# Key choices vs. base config:
#   • Shorter cache TTL  — see live API responses without flushing manually
#   • Relaxed rate limit — only one developer; no need to self-throttle
#   • High CB threshold  — don't open the circuit on exploratory errors
#   • Verbose logging    — see every request/response in the console
#   • Telemetry logger   — attach the default handler for request tracing
#
# Credentials are read from env vars (or a .envrc / .env file via direnv).
# Placeholder fallbacks let you start the app without real credentials —
# API calls will simply fail with 401 until you supply real values.
#
# Example .envrc (add to .gitignore):
#   export AURINKO_CLIENT_ID=your_dev_app_client_id
#   export AURINKO_CLIENT_SECRET=your_dev_app_client_secret
#   export AURINKO_WEBHOOK_SECRET=your_dev_webhook_secret
# =============================================================================

config :aurinko,
  # ---------------------------------------------------------------------------
  # Credentials
  # Compile-time read from env. runtime.exs re-reads these at boot so the
  # runtime value always wins — these lines are a convenient local override
  # for iex/mix tasks that don't invoke the full OTP start sequence.
  # ---------------------------------------------------------------------------
  client_id: System.get_env("AURINKO_CLIENT_ID", "dev_placeholder_id"),
  client_secret: System.get_env("AURINKO_CLIENT_SECRET", "dev_placeholder_secret"),
  webhook_secret: System.get_env("AURINKO_WEBHOOK_SECRET", "dev_placeholder_webhook_secret"),

  # ---------------------------------------------------------------------------
  # API
  # Swap to a local stub if you want to develop without hitting the real API:
  #   base_url: "http://localhost:8080/v1"
  # ---------------------------------------------------------------------------
  base_url: "https://api.aurinko.io/v1",

  # ---------------------------------------------------------------------------
  # HTTP Client
  # Generous timeout lets you place breakpoints without requests failing.
  # ---------------------------------------------------------------------------
  timeout: 60_000,
  pool_size: 5,

  # ---------------------------------------------------------------------------
  # Retry
  # Just 1 retry in dev — surface failures immediately instead of masking them.
  # ---------------------------------------------------------------------------
  retry_attempts: 1,
  retry_delay: 200,

  # ---------------------------------------------------------------------------
  # Cache
  # Short TTL so you see live API data. Call Cache.flush() to force a refresh.
  # ---------------------------------------------------------------------------
  cache_enabled: true,
  cache_ttl: 10_000,
  cache_max_size: 500,
  cache_cleanup_interval: 10_000,

  # ---------------------------------------------------------------------------
  # Rate Limiter
  # Permissive — only one developer. Actual Aurinko API limits still apply.
  # ---------------------------------------------------------------------------
  rate_limiter_enabled: true,
  rate_limit_per_token: 30,
  rate_limit_global: 300,
  rate_limit_burst: 30,

  # ---------------------------------------------------------------------------
  # Circuit Breaker
  # High threshold so accidental bad requests don't trip the circuit and make
  # subsequent valid calls mysteriously fail.
  # ---------------------------------------------------------------------------
  circuit_breaker_enabled: true,
  circuit_breaker_threshold: 20,
  circuit_breaker_timeout: 5_000,

  # ---------------------------------------------------------------------------
  # Telemetry
  # Attach the structured logger — every request/response prints to console.
  # Disable if the output is too noisy for your taste.
  # ---------------------------------------------------------------------------
  attach_default_telemetry: true,

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  log_level: :debug

# Logger: human-readable format with metadata for local development.
config :logger,
  level: :debug

config :logger, :console,
  format: "\n[$level] $time $metadata\n$message\n",
  metadata: [:module, :function, :line],
  colors: [enabled: true]
