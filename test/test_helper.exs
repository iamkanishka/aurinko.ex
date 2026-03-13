ExUnit.start()

Application.ensure_all_started(:bypass)

Application.put_env(:aurinko, :client_id, "test_client_id")
Application.put_env(:aurinko, :client_secret, "test_client_secret")
Application.put_env(:aurinko, :timeout, 5_000)
Application.put_env(:aurinko, :retry_attempts, 0)
Application.put_env(:aurinko, :retry_delay, 10)
Application.put_env(:aurinko, :cache_enabled, true)
Application.put_env(:aurinko, :cache_ttl, 60_000)
Application.put_env(:aurinko, :rate_limiter_enabled, false)
Application.put_env(:aurinko, :circuit_breaker_enabled, false)
Application.put_env(:aurinko, :attach_default_telemetry, false)
