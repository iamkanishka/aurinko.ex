# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] — 2025-03-16

### Added

#### API

- `Aurinko.Auth` — OAuth authorization URL builder, code exchange, and token refresh
- `Aurinko.APIs.Email` — List, get, send, draft, update messages; delta sync; attachments; email tracking
- `Aurinko.APIs.Calendar` — List/get calendars and events; create/update/delete events; delta sync; free/busy
- `Aurinko.APIs.Contacts` — CRUD contacts; delta sync
- `Aurinko.APIs.Tasks` — Task list and task management (list, create, update, delete)
- `Aurinko.APIs.Webhooks` — Subscription management (list, create, delete)
- `Aurinko.APIs.Booking` — Booking profile listing and availability
- `Aurinko.Types` — Typed structs for Email, CalendarEvent, Calendar, Contact, Task, Pagination, SyncResult
- `Aurinko.Error` — Structured, tagged error type with HTTP status mapping
- `Aurinko.HTTP.Client` — Req-based HTTP client with retry, backoff, and connection pooling
- `Aurinko.Telemetry` — `:telemetry` events for all HTTP requests
- `Aurinko.Config` — NimbleOptions-validated configuration
- Full typespecs and `@moduledoc`/`@doc` coverage
- GitHub Actions CI with matrix testing (Elixir 1.16/1.17, OTP 26/27)
- Credo strict linting and Dialyzer integration

#### Middleware & Infrastructure

- **`Aurinko.Cache`** — ETS-backed TTL response cache for all `GET` requests
  - Configurable TTL (default 60 s), max size (default 5 000 entries), and cleanup interval
  - LRU eviction when the entry limit is reached
  - Per-token cache invalidation via `invalidate_token/1`
  - Hit/miss/eviction statistics via `stats/0`
  - SHA-256 cache key derivation from `{token, path, params}`
  - `get/1`, `put/3`, `delete/1`, `flush/0`, `build_key/3` public API

- **`Aurinko.RateLimiter`** — Token-bucket rate limiter with dual buckets
  - Per-token bucket (default 10 req/s) and global bucket (default 100 req/s)
  - Configurable burst allowance (default +5 over steady-state)
  - Returns `:ok` or `{:wait, ms}` — the HTTP client sleeps and continues automatically
  - `check_rate/1`, `reset_token/1`, `inspect_bucket/1` public API
  - ETS-backed buckets with automatic cleanup of stale entries after 5 min of inactivity

- **`Aurinko.CircuitBreaker`** — Per-endpoint circuit breaker (closed → open → half-open)
  - Configurable failure threshold (default 5) and recovery timeout (default 30 s)
  - Tracks `server_error`, `network_error`, and `timeout` failure types; ignores `not_found` etc.
  - Half-open probe on timeout expiry; re-opens on probe failure, closes on probe success
  - `call/2`, `status/1`, `reset/1` public API
  - ETS-backed state machine; named per normalised URL path (IDs replaced with `:id`)

#### HTTP Client (rewritten)

- **`Aurinko.HTTP.Client`** — Req 0.5-based HTTP client with full middleware pipeline
  - Pipeline order: Rate Limiting → Cache Lookup → Circuit Breaker → HTTP + Retry → Cache Write → Telemetry
  - Exponential backoff with jitter for `429` and `5xx` responses
  - `Retry-After` header parsing for `429` responses
  - Structured `%Aurinko.Error{}` on all failure paths (no raw exceptions leak)
  - Request packing via `req_info` map to keep internal function arities ≤ 8
  - `get/3`, `post/4`, `patch/4`, `put/4`, `delete/3` public API

#### Streaming Pagination

- **`Aurinko.Paginator`** — Lazy `Stream`-based pagination for all list endpoints
  - `stream/3` — streams records across all pages on demand, never loading all into memory
  - `sync_stream/4` — streams delta-sync records; captures `next_delta_token` via `:on_delta` callback
  - `collect_all/3` — synchronous convenience wrapper returning `{:ok, list}`
  - Configurable `:on_error` — `:halt` (default) or `:skip` per-page error handling

#### Sync Orchestrator

- **`Aurinko.Sync.Orchestrator`** — High-level delta-sync lifecycle manager
  - `sync_email/2` — full or incremental email sync; resolves or provisions delta tokens automatically
  - `sync_calendar/3` — calendar sync with configurable `time_min`/`time_max` window
  - `sync_contacts/2` — contacts sync (updated records only; no deleted stream)
  - Accepts `:get_tokens`, `:save_tokens`, `:on_updated`, `:on_deleted` callbacks
  - Automatic retry with backoff when Aurinko sync is not yet `:ready`
  - Records are delivered in batches of 200 via `Stream.chunk_every/2`

#### Webhook Support

- **`Aurinko.Webhook.Verifier`** — HMAC-SHA256 signature verification
  - `verify/3` — validates `sha256=<hex>` signature header; returns `:ok` or `{:error, :invalid_signature}`
  - `sign/2` — test helper for generating valid signatures
  - Constant-time comparison via `:crypto.hash/2` to prevent timing attacks (no `plug_crypto` dependency)

- **`Aurinko.Webhook.Handler`** — Behaviour + dispatcher for webhook event processing
  - `dispatch/4` — parses raw body, optionally verifies signature, routes `eventType` to handler module
  - `@callback handle_event/3` behaviour for implementing custom handlers

#### Observability

- **`Aurinko.Telemetry`** (expanded) — 7 telemetry events now emitted
  - `[:aurinko, :request, :start]` — before each HTTP request
  - `[:aurinko, :request, :stop]` — after each HTTP request (includes duration, cached flag)
  - `[:aurinko, :request, :retry]` — on each retry attempt (includes reason: `:rate_limited`, `:server_error`, `:timeout`)
  - `[:aurinko, :circuit_breaker, :opened]` — when a circuit opens (threshold exceeded or probe failure)
  - `[:aurinko, :circuit_breaker, :closed]` — when a circuit recovers
  - `[:aurinko, :circuit_breaker, :rejected]` — when a request is rejected by an open circuit
  - `[:aurinko, :sync, :complete]` — after a full sync run (updated count, deleted count, duration)
  - `attach_default_logger/0` and `detach_default_logger/0` for zero-config structured logging
  - `Telemetry.Metrics` definitions for Prometheus / StatsD reporters

- **`Aurinko.Logger.JSONFormatter`** — Structured JSON log formatter
  - One JSON object per log line: `time`, `level`, `msg`, `pid`, `module`, `function`, `line`, `request_id`
  - Compatible with Datadog, Loki, Google Cloud Logging, and other log aggregation pipelines
  - Plug-in via `config :logger, :console, format: {Aurinko.Logger.JSONFormatter, :format}`

#### OTP Application

- **`Aurinko.Application`** — Supervised OTP application with ordered start-up
  - Supervision order: Cache → RateLimiter → CircuitBreaker → HTTP.Client → Telemetry
  - Fail-fast config validation on start (raises `Aurinko.ConfigError` if credentials missing)
  - Structured startup summary logged at `:info` level
  - 5-second graceful shutdown timeout per child

#### Configuration (expanded)

- `Aurinko.Config` extended with new validated keys (all via `NimbleOptions`):
  - Cache: `:cache_enabled`, `:cache_ttl`, `:cache_max_size`, `:cache_cleanup_interval`
  - Rate limiter: `:rate_limiter_enabled`, `:rate_limit_per_token`, `:rate_limit_global`, `:rate_limit_burst`
  - Circuit breaker: `:circuit_breaker_enabled`, `:circuit_breaker_threshold`, `:circuit_breaker_timeout`
  - Telemetry: `:attach_default_telemetry`
  - `Config.merge/2` utility for per-request config overrides

#### Developer Experience

- **Guides** — `guides/getting_started.md` and `guides/advanced.md` added to ExDoc
- **CI** extended — Credo strict, Dialyzer, and ExCoveralls added as required checks
  - Elixir 1.16 / OTP 26 and Elixir 1.17 / OTP 27 matrix
  - Lint, format check, and Dialyzer run as separate CI jobs
- New `mix` aliases: `lint`, `test.all`, `quality`
- `config/staging.exs` — staging environment config with JSON logging pre-configured
- `config/runtime.exs` — runtime config reading all settings from environment variables

### Changed

- `Aurinko.HTTP.Client` completely rewritten — previously a thin `Req` wrapper; now a full GenServer with the middleware pipeline described above
- `Aurinko.Telemetry` expanded from request-only events to 7 events covering the full request lifecycle, circuit breaker state changes, and sync completion
- `Aurinko.Config` schema extended; `load!/0` now strips unknown application env keys before validation to avoid conflicts with middleware config keys
- All API functions (`Email`, `Calendar`, `Contacts`, `Tasks`, `Webhooks`, `Booking`) now route through the full middleware pipeline automatically

### Fixed

- Dialyzer: removed unreachable `is_list` guard clause from `get_header/2` (Req 0.5 always returns headers as a map)
- Dialyzer: narrowed `@spec format/4` return in `JSONFormatter` from `iodata()` to `binary()`
- Dialyzer: removed `{:error, :rate_limit_exceeded}` from `RateLimiter` type and spec (function never returns it)
- Dialyzer: narrowed `@spec events/0` in `Telemetry` from `list(list(atom()))` to `nonempty_list(nonempty_list(atom()))`
- Webhook verifier: replaced `Plug.Crypto.secure_compare/2` (undeclared dependency) with a self-contained `:crypto`-based constant-time comparison

---

## [0.1.0] — 2025-06-01

### Added

- Initial release with Starter Boilerplate elxir app 

[Unreleased]: https://github.com/yourusername/aurinko/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/yourusername/aurinko/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/yourusername/aurinko/releases/tag/v0.1.0
