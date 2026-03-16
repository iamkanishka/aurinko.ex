# Getting Started with Aurinko

This guide walks you through setting up Aurinko in your Elixir application from scratch.

## Prerequisites

- Elixir ~> 1.18
- An [Aurinko account](https://app.aurinko.io) with developer API keys

## 1. Install

Add `aurinko` to your dependencies:

```elixir
# mix.exs
defp deps do
  [{:aurinko, "~> 0.2.1"}]
end
```

```bash
mix deps.get
```

## 2. Configure

```elixir
# config/runtime.exs
config :aurinko,
  client_id: System.fetch_env!("AURINKO_CLIENT_ID"),
  client_secret: System.fetch_env!("AURINKO_CLIENT_SECRET")
```

Set environment variables:

```bash
export AURINKO_CLIENT_ID=your_client_id_here
export AURINKO_CLIENT_SECRET=your_client_secret_here
```

### Optional configuration

```elixir
# config/runtime.exs
config :aurinko,
  client_id:     System.fetch_env!("AURINKO_CLIENT_ID"),
  client_secret: System.fetch_env!("AURINKO_CLIENT_SECRET"),
  timeout:       30_000,        # HTTP request timeout in ms (default: 30_000)
  retry_attempts: 3,            # Retry attempts on 429/5xx (default: 3)
  cache_enabled:  true,         # ETS response cache (default: true)
  cache_ttl:      60_000,       # Cache entry TTL in ms (default: 60_000)
  rate_limiter_enabled: true,   # Per-token + global rate limiter (default: true)
  circuit_breaker_enabled: true # Per-endpoint circuit breaker (default: true)
```

See `Aurinko.Config` for the full list of supported keys.

## 3. Authenticate a User

### Redirect to Aurinko's OAuth page

```elixir
url = Aurinko.authorize_url(
  service_type: "Google",
  scopes: ["Mail.Read", "Calendars.ReadWrite"],
  return_url: "https://yourapp.com/auth/callback"
)

# In a Phoenix controller:
redirect(conn, external: url)
```

Supported `service_type` values include `"Google"`, `"Office365"`, `"EWS"`, `"IMAP"`, `"Outlook"`, and others — see the [Aurinko docs](https://docs.aurinko.io) for the full list.

### Handle the callback

```elixir
# In your callback controller action:
def callback(conn, %{"code" => code}) do
  {:ok, %{token: token, email: email}} = Aurinko.Auth.exchange_code(code)

  # Store `token` in your database — it's needed for every subsequent API call
  conn
  |> put_session(:aurinko_token, token)
  |> redirect(to: "/dashboard")
end
```

### Refresh a token

```elixir
{:ok, %{token: new_token}} = Aurinko.Auth.refresh_token(refresh_token)
```

## 4. Make API Calls

```elixir
token = get_session(conn, :aurinko_token)

# Read emails
{:ok, page} = Aurinko.list_messages(token, limit: 10, q: "is:unread")
# page.records  => list of email maps
# page.next_page_token => pass to next call for more pages

# Read calendar events
{:ok, page} = Aurinko.list_events(token, "primary",
  time_min: DateTime.utc_now(),
  time_max: DateTime.add(DateTime.utc_now(), 7, :day)
)

# Send an email
{:ok, sent} = Aurinko.send_message(token, %{
  to: [%{address: "recipient@example.com", name: "Recipient"}],
  subject: "Hello from Aurinko",
  body: "<h1>Hello!</h1>",
  body_type: "html"
})
```

All API functions return `{:ok, result}` on success or `{:error, %Aurinko.Error{}}` on failure. See the [Error Handling](#error-handling) section of the Advanced guide for details.

## 5. Implement Sync (recommended for production)

Aurinko uses a **delta token** model. The first sync fetches everything; subsequent syncs fetch only changes since the last token.

### Simple approach (manual pagination)

```elixir
defmodule MyApp.EmailSync do
  def sync(token) do
    {:ok, sync} = Aurinko.APIs.Email.start_sync(token, days_within: 30)

    if sync.ready do
      load_all_updated(token, sync.sync_updated_token)
    else
      # Aurinko is still initializing — retry shortly
      {:retry}
    end
  end

  defp load_all_updated(token, delta_or_page_token, acc \\ []) do
    {:ok, page} = Aurinko.APIs.Email.sync_updated(token, delta_or_page_token)
    messages = acc ++ page.records

    cond do
      page.next_page_token ->
        load_all_updated(token, page.next_page_token, messages)

      page.next_delta_token ->
        # Persist the new token for the next incremental sync
        MyApp.Store.save_delta_token(page.next_delta_token)
        {:ok, messages}
    end
  end
end
```

### Recommended approach (Orchestrator)

For production use, `Aurinko.Sync.Orchestrator` handles token resolution, pagination,
batching, and token persistence automatically:

```elixir
{:ok, result} = Aurinko.Sync.Orchestrator.sync_email(token,
  days_within: 30,
  on_updated: fn records -> MyApp.Mailbox.upsert_many(records) end,
  on_deleted: fn ids    -> MyApp.Mailbox.delete_by_ids(ids) end,
  get_tokens:  fn       -> MyApp.Store.get_delta_tokens("email") end,
  save_tokens: fn toks  -> MyApp.Store.save_delta_tokens("email", toks) end
)

Logger.info("Sync complete: #{result.updated} updated, #{result.deleted} deleted in #{result.duration_ms}ms")
```

See the [Sync Orchestration](advanced.html#high-level-sync-orchestration) section of the Advanced guide for the full calendar and contacts variants.

## 6. Enable Telemetry (optional)

Aurinko emits [`:telemetry`](https://hexdocs.pm/telemetry) events for every request,
retry, circuit breaker state change, and sync completion.

### Zero-config structured logging

```elixir
# In your Application.start/2 or config/runtime.exs:
Aurinko.Telemetry.attach_default_logger(:info)
```

This logs every request, retry, and circuit breaker event to your standard Logger output.

### Custom metrics integration

```elixir
:telemetry.attach(
  "aurinko-metrics",
  [:aurinko, :request, :stop],
  fn _event, %{duration: d}, %{result: r}, _cfg ->
    MyApp.Metrics.increment("aurinko.request.#{r}",
      value: System.convert_time_unit(d, :native, :millisecond)
    )
  end,
  nil
)
```

See the [Telemetry Integration](advanced.html#telemetry-integration) section of the
Advanced guide for the full event catalogue and Prometheus/Datadog examples.

## 7. JSON Logging for Production (optional)

In `prod.exs` or `staging.exs`, switch to structured JSON logs for log aggregation pipelines:

```elixir
# config/prod.exs
config :logger, :console,
  format:   {Aurinko.Logger.JSONFormatter, :format},
  metadata: [:request_id, :module, :function, :line, :pid]
```

Each log line becomes a single JSON object compatible with Datadog, Loki, Google Cloud Logging, and similar systems.

## Next Steps

- **[Advanced Guide](advanced.html)** — Caching, rate limiting, circuit breaker, streaming pagination, webhook verification, telemetry, and error handling in depth
- **[`Aurinko`](Aurinko.html)** — Top-level module with delegated API shortcuts
- **[`Aurinko.APIs.Email`](Aurinko.APIs.Email.html)** — Full email API reference
- **[`Aurinko.APIs.Calendar`](Aurinko.APIs.Calendar.html)** — Full calendar API reference
- **[`Aurinko.Sync.Orchestrator`](Aurinko.Sync.Orchestrator.html)** — Sync lifecycle reference