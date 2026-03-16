# Advanced Usage Guide

## Caching

Aurinko caches all GET responses in an ETS table by default.

```elixir
# Configure caching
config :aurinko,
  cache_enabled: true,
  cache_ttl: 60_000,          # 60 seconds
  cache_max_size: 5_000,      # entries
  cache_cleanup_interval: 30_000

# Bypass cache for a specific request
{:ok, fresh} = Aurinko.list_messages(token, bypass_cache: true)

# Custom TTL per request
{:ok, _} = Aurinko.list_calendars(token, cache_ttl: 300_000)  # 5 minutes

# Invalidate all cached data for a token (e.g. after token refresh)
Aurinko.Cache.invalidate_token(old_token)

# Check cache stats
%{hits: h, misses: m, evictions: e, size: s} = Aurinko.Cache.stats()
```

---

## Rate Limiting

Token-bucket algorithm with per-account and global buckets.

```elixir
config :aurinko,
  rate_limiter_enabled: true,
  rate_limit_per_token: 10,   # req/sec per token
  rate_limit_global: 100,     # req/sec global
  rate_limit_burst: 5         # burst headroom

# The HTTP client handles waiting automatically.
# For manual control:
case Aurinko.RateLimiter.check_rate(token) do
  :ok               -> proceed()
  {:wait, delay_ms} -> Process.sleep(delay_ms); proceed()
end

# Inspect current bucket state
bucket = Aurinko.RateLimiter.inspect_bucket(token)
IO.inspect(bucket)  # %{tokens: 9.2, rate: 10.0, capacity: 15.0}

# Reset after a 429 (e.g. with Retry-After: 60)
Aurinko.RateLimiter.reset_token(token)
```

---

## Circuit Breaker

Automatically opens after N consecutive server errors, then probes with a single request after a cooldown.

```elixir
config :aurinko,
  circuit_breaker_enabled: true,
  circuit_breaker_threshold: 5,      # failures to open
  circuit_breaker_timeout: 30_000    # ms before half-open probe

# Status monitoring
%{state: :closed | :open | :half_open, failure_count: n} =
  Aurinko.CircuitBreaker.status("get:/email/messages")

# Manual reset (e.g. after deploying a fix)
Aurinko.CircuitBreaker.reset("get:/email/messages")
```

When the circuit is open, requests return `{:error, :circuit_open}` immediately without touching the network.

---

## Streaming Pagination

Never manually track `next_page_token` again:

```elixir
# Lazy stream — fetches pages only as consumed
Aurinko.Paginator.stream(token, &Aurinko.list_messages/2, q: "is:unread")
|> Stream.take(100)
|> Enum.to_list()

# Process in batches
Aurinko.Paginator.stream(token, &Aurinko.list_contacts/2)
|> Stream.chunk_every(50)
|> Stream.each(fn batch -> MyApp.Contacts.upsert_batch(batch) end)
|> Stream.run()

# Collect everything
{:ok, all_events} = Aurinko.Paginator.collect_all(
  token,
  fn t, opts -> Aurinko.list_events(t, "primary", opts) end,
  time_min: ~U[2024-01-01 00:00:00Z],
  time_max: ~U[2024-12-31 23:59:59Z]
)
```

---

## High-level Sync Orchestration

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
      on_deleted: fn ids -> MyApp.Mailbox.delete_by_ids(ids) end,
      get_tokens: fn -> MyApp.Store.get_delta_tokens(account.id, "email") end,
      save_tokens: fn tokens -> MyApp.Store.save_delta_tokens(account.id, "email", tokens) end
    )

    Logger.info("Sync done: #{result.updated} updated, #{result.deleted} deleted")
  end
end
```

---

## Webhook Verification

```elixir
# Phoenix controller
defmodule MyAppWeb.WebhookController do
  use MyAppWeb, :controller

  # Must read raw body — add to router:
  # plug :read_raw_body when action == :receive

  def receive(conn, _params) do
    signature = get_req_header(conn, "x-aurinko-signature") |> List.first()
    raw_body = conn.assigns[:raw_body]

    case Aurinko.Webhook.Verifier.verify(raw_body, signature) do
      :ok ->
        payload = Jason.decode!(raw_body)
        Aurinko.Webhook.Handler.dispatch(MyApp.WebhookHandler, raw_body)
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        send_resp(conn, 401, "invalid signature")
    end
  end
end

# Handler behaviour
defmodule MyApp.WebhookHandler do
  @behaviour Aurinko.Webhook.Handler

  @impl true
  def handle_event("email.new", %{"data" => data}, _meta) do
    MyApp.Mailbox.process_incoming(data)
  end

  def handle_event("calendar.event.updated", payload, _meta) do
    MyApp.Calendar.handle_change(payload)
  end

  def handle_event(_event, _payload, _meta), do: :ok
end
```

---

## Telemetry Integration

```elixir
# In your Phoenix Telemetry module
def metrics do
  [
    ...phoenix_metrics...,
    Aurinko.Telemetry.metrics()
  ]
  |> List.flatten()
end

# Custom handler for Datadog/StatsD
:telemetry.attach_many(
  "aurinko-datadog",
  Aurinko.Telemetry.events(),
  fn
    [:aurinko, :request, :stop], %{duration: d}, %{method: m, result: r}, _ ->
      ms = System.convert_time_unit(d, :native, :millisecond)
      Datadog.histogram("aurinko.request.duration", ms, tags: ["method:#{m}", "result:#{r}"])
      Datadog.increment("aurinko.request.count", tags: ["method:#{m}", "result:#{r}"])

    [:aurinko, :circuit_breaker, :opened], _, %{circuit: c}, _ ->
      Datadog.event("Aurinko circuit opened", c, alert_type: :error)

    _, _, _, _ -> :ok
  end,
  nil
)
```

---

## Error Handling

```elixir
case Aurinko.get_message(token, "msg_id") do
  {:ok, message} -> process(message)
  {:error, %Aurinko.Error{type: :not_found}} -> Logger.info("Message deleted")
  {:error, %Aurinko.Error{type: :auth_error}} -> refresh_and_retry(token)
  {:error, %Aurinko.Error{type: :rate_limited}} -> schedule_retry_later()
  {:error, %Aurinko.Error{type: t, message: msg}} -> Logger.error("#{t}: #{msg}")
end
```

Error types: `:auth_error | :not_found | :rate_limited | :server_error | :network_error | :timeout | :invalid_params | :config_error | :unknown`
