# Advanced Usage Guide

This guide covers the production-grade features added in v0.2.0: caching, rate limiting,
circuit breaking, streaming pagination, sync orchestration, webhooks, telemetry, and error handling.

---

## Caching

Aurinko caches all `GET` responses in an ETS table automatically. The cache key is derived
from the SHA-256 hash of `{token, path, params}`, so different tokens and query parameters
each get their own entries.

```elixir
# config/runtime.exs
config :aurinko,
  cache_enabled:          true,
  cache_ttl:              60_000,   # entry TTL in ms (default: 60 s)
  cache_max_size:         5_000,    # max entries before LRU eviction (default: 5 000)
  cache_cleanup_interval: 30_000    # expired entry sweep interval in ms (default: 30 s)
```

### Per-request overrides

```elixir
# Bypass the cache entirely for a single request
{:ok, fresh} = Aurinko.list_messages(token, bypass_cache: true)

# Custom TTL for a specific request
{:ok, _} = Aurinko.list_calendars(token, cache_ttl: 300_000)  # 5 minutes
```

### Cache management

```elixir
# Invalidate all cached entries for a token (e.g. after a token refresh)
Aurinko.Cache.invalidate_token(old_token)

# Delete a specific cache entry by key
Aurinko.Cache.delete(cache_key)

# Flush the entire cache
Aurinko.Cache.flush()

# Check cache statistics
%{hits: h, misses: m, evictions: e, size: s} = Aurinko.Cache.stats()
```

---

## Rate Limiting

Aurinko uses a token-bucket algorithm with two independent buckets: one per Aurinko token
(per-account) and one global bucket shared across all accounts. If either bucket is exhausted,
the HTTP client sleeps for the calculated wait time and retries automatically — no action
required from your code.

```elixir
config :aurinko,
  rate_limiter_enabled:  true,
  rate_limit_per_token:  10,   # req/sec per account token (default: 10)
  rate_limit_global:     100,  # req/sec across all tokens (default: 100)
  rate_limit_burst:      5     # burst headroom above steady-state (default: 5)
```

### Manual rate check

```elixir
# Check before dispatching work from a queue
case Aurinko.RateLimiter.check_rate(token) do
  :ok               -> proceed()
  {:wait, delay_ms} -> Process.sleep(delay_ms); proceed()
end
```

### Monitoring and reset

```elixir
# Inspect the current bucket state for a token
bucket = Aurinko.RateLimiter.inspect_bucket(token)
# => %{tokens: 9.2, rate: 10.0, capacity: 15.0, last_refill: ...}

# Reset a bucket after receiving a 429 with a Retry-After header
Aurinko.RateLimiter.reset_token(token)
```

---

## Circuit Breaker

The circuit breaker prevents cascading failures when Aurinko's API is degraded.
It tracks failures per normalised URL path (dynamic IDs are replaced with `:id`).

**State machine:** `closed` → `open` (after N failures) → `half-open` (after timeout) → `closed` (on probe success) or `open` (on probe failure).

```elixir
config :aurinko,
  circuit_breaker_enabled:   true,
  circuit_breaker_threshold: 5,       # consecutive server/network/timeout failures to open (default: 5)
  circuit_breaker_timeout:   30_000   # ms before half-open probe (default: 30 s)
```

Only `:server_error`, `:network_error`, and `:timeout` failures count toward the threshold.
Client errors (`:not_found`, `:auth_error`, `:invalid_params`) do not open the circuit.

When open, requests return `{:error, :circuit_open}` immediately without touching the network.

### Monitoring and manual control

```elixir
# Inspect circuit state
%{state: :closed, failure_count: 0} =
  Aurinko.CircuitBreaker.status("get:/email/messages")

# All possible states
%{state: :closed | :open | :half_open, failure_count: n, opened_at: t} =
  Aurinko.CircuitBreaker.status("get:/email/messages")

# Manually reset a circuit (e.g. after deploying a fix)
Aurinko.CircuitBreaker.reset("get:/email/messages")
```

---

## Streaming Pagination

Never manually track `next_page_token` again. `Aurinko.Paginator` wraps any list function
in a lazy `Stream` that fetches the next page only when the consumer needs it.

### `stream/3` — regular pagination

```elixir
# Lazy stream — only fetches pages as consumed
Aurinko.Paginator.stream(token, &Aurinko.APIs.Email.list_messages/2, q: "is:unread")
|> Stream.take(100)
|> Enum.to_list()

# Process in batches without loading everything into memory
Aurinko.Paginator.stream(token, &Aurinko.APIs.Contacts.list_contacts/2)
|> Stream.chunk_every(50)
|> Stream.each(fn batch -> MyApp.Contacts.upsert_batch(batch) end)
|> Stream.run()

# Collect all pages into a list
{:ok, all_events} = Aurinko.Paginator.collect_all(
  token,
  fn t, opts -> Aurinko.APIs.Calendar.list_events(t, "primary", opts) end,
  time_min: ~U[2024-01-01 00:00:00Z],
  time_max: ~U[2024-12-31 23:59:59Z]
)
```

### `sync_stream/4` — delta-sync pagination

Use this when draining a sync endpoint that returns both `next_page_token` (more records in
this batch) and `next_delta_token` (batch complete, use this token next time):

```elixir
{:ok, sync} = Aurinko.APIs.Email.start_sync(token, days_within: 30)

Aurinko.Paginator.sync_stream(
  token,
  sync.sync_updated_token,
  &Aurinko.APIs.Email.sync_updated/2,
  on_delta: fn new_token ->
    # Called once when all pages are drained — persist the new token
    MyApp.Store.save_delta_token(new_token)
  end
)
|> Stream.each(&MyApp.Mailbox.process_message/1)
|> Stream.run()
```

### Error handling in streams

```elixir
# Default: halt stream on error (returns {:error, reason} as the last element)
stream = Aurinko.Paginator.stream(token, &Aurinko.APIs.Email.list_messages/2,
  on_error: :halt)

# Skip errored pages and continue
stream = Aurinko.Paginator.stream(token, &Aurinko.APIs.Email.list_messages/2,
  on_error: :skip)
```

---

## High-level Sync Orchestration

`Aurinko.Sync.Orchestrator` manages the entire delta-sync lifecycle: token resolution or
provisioning, pagination, batch delivery, and token persistence — with automatic retry when
Aurinko's sync is still initializing.

### Email sync

```elixir
defmodule MyApp.Sync do
  def run_email_sync(account) do
    {:ok, result} = Aurinko.Sync.Orchestrator.sync_email(account.token,
      days_within: 30,
      on_updated: fn records ->
        records
        |> Enum.map(&Aurinko.Types.Email.from_response/1)
        |> MyApp.Mailbox.upsert_many()
      end,
      on_deleted: fn ids    -> MyApp.Mailbox.delete_by_ids(ids) end,
      get_tokens:  fn       -> MyApp.Store.get_delta_tokens(account.id, "email") end,
      save_tokens: fn toks  -> MyApp.Store.save_delta_tokens(account.id, "email", toks) end
    )

    Logger.info("Email sync done: #{result.updated} updated, #{result.deleted} deleted in #{result.duration_ms}ms")
  end
end
```

### Calendar sync

```elixir
{:ok, result} = Aurinko.Sync.Orchestrator.sync_calendar(token, "primary",
  time_min: ~U[2024-01-01 00:00:00Z],
  time_max: ~U[2024-12-31 23:59:59Z],
  on_updated: fn records -> MyApp.Calendar.upsert_events(records) end,
  on_deleted: fn ids     -> MyApp.Calendar.delete_events(ids) end,
  get_tokens:  fn        -> MyApp.Store.get_delta_tokens(account.id, "calendar:primary") end,
  save_tokens: fn toks   -> MyApp.Store.save_delta_tokens(account.id, "calendar:primary", toks) end
)
```

### Contacts sync

```elixir
{:ok, result} = Aurinko.Sync.Orchestrator.sync_contacts(token,
  on_updated: fn records -> MyApp.Contacts.upsert_many(records) end,
  get_tokens:  fn        -> MyApp.Store.get_delta_tokens(account.id, "contacts") end,
  save_tokens: fn toks   -> MyApp.Store.save_delta_tokens(account.id, "contacts", toks) end
)
```

### Callback reference

| Option | Required | Description |
|---|---|---|
| `:on_updated` | no | Called with each batch of up to 200 updated records |
| `:on_deleted` | no | Called with each batch of deleted record IDs |
| `:get_tokens` | no | Returns `%{sync_updated_token: _, sync_deleted_token: _}` or `nil` for a fresh sync |
| `:save_tokens` | **yes** | Persists the new delta tokens after a successful sync |
| `:days_within` | no | (email only) Limit initial scan to emails from the past N days (default: 30) |
| `:time_min` / `:time_max` | no | (calendar only) Initial sync window (defaults: ±365 days) |

---

## Webhook Verification

Aurinko signs outgoing webhook payloads with your client secret. Always verify signatures
in production.

### Phoenix controller

```elixir
defmodule MyAppWeb.WebhookController do
  use MyAppWeb, :controller

  # Read the raw body before Jason parses it — add to your router:
  # plug :read_raw_body when action == :receive

  def receive(conn, _params) do
    signature = get_req_header(conn, "x-aurinko-signature") |> List.first()
    raw_body  = conn.assigns[:raw_body]

    case Aurinko.Webhook.Verifier.verify(raw_body, signature) do
      :ok ->
        Aurinko.Webhook.Handler.dispatch(MyApp.WebhookHandler, raw_body, signature)
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        send_resp(conn, 401, "invalid signature")
    end
  end
end
```

### Implementing the handler behaviour

```elixir
defmodule MyApp.WebhookHandler do
  @behaviour Aurinko.Webhook.Handler

  @impl true
  def handle_event("email.new", %{"data" => data}, _meta) do
    MyApp.Mailbox.process_incoming(data)
    :ok
  end

  def handle_event("calendar.event.updated", payload, _meta) do
    MyApp.Calendar.handle_change(payload)
    :ok
  end

  def handle_event(_event, _payload, _meta), do: :ok
end
```

The `meta` argument contains `%{raw_body: binary(), verified: boolean()}`.

### Generating test signatures

```elixir
# In tests or a dev console:
sig = Aurinko.Webhook.Verifier.sign(raw_body, "your_webhook_secret")
# => "sha256=abc123..."
```

---

## Telemetry Integration

Aurinko emits 7 telemetry events. All measurements use `:native` time units unless noted.

| Event | Measurements | Metadata |
|---|---|---|
| `[:aurinko, :request, :start]` | `system_time` | `method`, `path` |
| `[:aurinko, :request, :stop]` | `duration` | `method`, `path`, `result`, `cached` |
| `[:aurinko, :request, :retry]` | `count` | `method`, `path`, `reason` |
| `[:aurinko, :circuit_breaker, :opened]` | `count` | `circuit`, `reason` |
| `[:aurinko, :circuit_breaker, :closed]` | `count` | `circuit` |
| `[:aurinko, :circuit_breaker, :rejected]` | `count` | `circuit` |
| `[:aurinko, :sync, :complete]` | `updated`, `deleted`, `duration_ms` | `resource` |

### Phoenix LiveDashboard / Prometheus

```elixir
# In your Phoenix Telemetry module
def metrics do
  [
    ...your_existing_metrics...,
    Aurinko.Telemetry.metrics()
  ]
  |> List.flatten()
end
```

### Datadog / StatsD custom handler

```elixir
:telemetry.attach_many(
  "aurinko-datadog",
  Aurinko.Telemetry.events(),
  fn
    [:aurinko, :request, :stop], %{duration: d}, %{method: m, result: r, path: p}, _ ->
      ms = System.convert_time_unit(d, :native, :millisecond)
      Datadog.histogram("aurinko.request.duration", ms, tags: ["method:#{m}", "result:#{r}", "path:#{p}"])
      Datadog.increment("aurinko.request.count", tags: ["method:#{m}", "result:#{r}"])

    [:aurinko, :request, :retry], %{count: n}, %{reason: reason, path: p}, _ ->
      Datadog.increment("aurinko.retry", tags: ["reason:#{reason}", "path:#{p}", "attempt:#{n}"])

    [:aurinko, :circuit_breaker, :opened], _, %{circuit: c, reason: r}, _ ->
      Datadog.event("Aurinko circuit opened", "#{c} — #{r}", alert_type: :error)

    [:aurinko, :circuit_breaker, :rejected], _, %{circuit: c}, _ ->
      Datadog.increment("aurinko.circuit_breaker.rejected", tags: ["circuit:#{c}"])

    [:aurinko, :sync, :complete], %{updated: u, deleted: d, duration_ms: ms}, %{resource: r}, _ ->
      Datadog.histogram("aurinko.sync.duration", ms, tags: ["resource:#{r}"])
      Datadog.gauge("aurinko.sync.updated", u, tags: ["resource:#{r}"])
      Datadog.gauge("aurinko.sync.deleted", d, tags: ["resource:#{r}"])

    _, _, _, _ ->
      :ok
  end,
  nil
)
```

---

## Error Handling

Every Aurinko function returns either `{:ok, result}` or `{:error, %Aurinko.Error{}}`.
The `%Aurinko.Error{}` struct has three fields: `type`, `message`, and `status` (HTTP code, may be `nil`).

```elixir
case Aurinko.APIs.Email.get_message(token, "msg_id") do
  {:ok, message} ->
    process(message)

  {:error, %Aurinko.Error{type: :not_found}} ->
    Logger.info("Message no longer exists")

  {:error, %Aurinko.Error{type: :auth_error}} ->
    # Token expired — refresh and retry
    refresh_and_retry(token)

  {:error, %Aurinko.Error{type: :rate_limited, status: 429}} ->
    # The HTTP client retried automatically up to the configured limit.
    # This means all retries were exhausted.
    schedule_retry_later()

  {:error, %Aurinko.Error{type: :circuit_open}} ->
    # The circuit breaker is open — endpoint is considered down
    Logger.warning("Aurinko circuit open, skipping sync")

  {:error, %Aurinko.Error{type: type, message: msg, status: status}} ->
    Logger.error("Aurinko error #{type} (HTTP #{status}): #{msg}")
end
```

### Error type reference

| Type | HTTP Status | Description |
|---|---|---|
| `:auth_error` | 401 / 403 | Token invalid or expired |
| `:not_found` | 404 | Resource does not exist |
| `:rate_limited` | 429 | Rate limit exceeded after all retries |
| `:server_error` | 5xx | Aurinko server error after all retries |
| `:network_error` | — | Connection refused, DNS failure, etc. |
| `:timeout` | — | Request timed out after all retries |
| `:invalid_params` | — | Missing or invalid parameters (caught client-side) |
| `:config_error` | — | Missing required config key at startup |
| `:unknown` | other | Unmapped HTTP status |