# Aurinko

[![Hex.pm](https://img.shields.io/hexpm/v/aurinko_ex.svg)](https://hex.pm/packages/aurinko_ex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/aurinko_ex)
[![CI](https://github.com/yourusername/aurinko_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/yourusername/aurinko_ex/actions)
[![Coverage Status](https://coveralls.io/repos/github/yourusername/aurinko_ex/badge.svg)](https://coveralls.io/github/yourusername/aurinko_ex)

A production-grade Elixir client for the [Aurinko Unified Mailbox API](https://docs.aurinko.io) — covering **Email, Calendar, Contacts, Tasks, Webhooks, and Booking** across Google Workspace, Office 365, Outlook, MS Exchange, Zoho Mail, iCloud, and IMAP.

---

## Features

- ✅ Full coverage of Aurinko's Unified APIs (Email, Calendar, Contacts, Tasks, Webhooks, Booking)
- ✅ Type-safe structs for all response objects
- ✅ Delta/incremental sync model for all data categories
- ✅ Automatic retry with exponential backoff and jitter
- ✅ Rate limit handling (respects `Retry-After` headers)
- ✅ Telemetry instrumentation via `:telemetry`
- ✅ Structured, tagged error types (`{:error, %Aurinko.Error{}}`)
- ✅ Config validation with `NimbleOptions`
- ✅ Fully documented with typespecs and `@doc` coverage

---

## Installation

Add `aurinko_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:aurinko_ex, "~> 0.1"}
  ]
end
```

Then run:

```bash
mix deps.get
```

---

## Configuration

```elixir
# config/config.exs
config :aurinko_ex,
  client_id: System.get_env("AURINKO_CLIENT_ID"),
  client_secret: System.get_env("AURINKO_CLIENT_SECRET"),
  base_url: "https://api.aurinko.io/v1",   # default
  timeout: 30_000,                          # ms, default: 30s
  retry_attempts: 3,                        # default
  retry_delay: 500,                         # ms base, uses exponential backoff
  pool_size: 10                             # HTTP connection pool
```

For runtime configuration (e.g. `runtime.exs`):

```elixir
config :aurinko_ex,
  client_id: System.fetch_env!("AURINKO_CLIENT_ID"),
  client_secret: System.fetch_env!("AURINKO_CLIENT_SECRET")
```

---

## Authentication

### Step 1 — Build the authorization URL and redirect the user

```elixir
url = Aurinko.authorize_url(
  service_type: "Google",                          # or "Office365", "Zoho", "EWS", "IMAP"
  scopes: ["Mail.Read", "Mail.Send", "Calendars.ReadWrite", "Contacts.Read"],
  return_url: "https://yourapp.com/auth/callback",
  state: "csrf_token_here"
)

# Redirect the user's browser to `url`
```

### Step 2 — Exchange the authorization code for a token

```elixir
{:ok, %{token: token, account_id: id, email: email}} =
  Aurinko.Auth.exchange_code(params["code"])

# Store `token` securely — use it for all subsequent API calls
```

---

## Email API

```elixir
# List messages (with optional search)
{:ok, page} = Aurinko.list_messages(token,
  limit: 25,
  q: "from:[email protected] is:unread"
)

# Access records
Enum.each(page.records, fn raw_msg ->
  msg = Aurinko.Types.Email.from_response(raw_msg)
  IO.puts("#{msg.subject} — from #{msg.from.address}")
end)

# Get a single message
{:ok, msg} = Aurinko.get_message(token, "msg_id_123", body_type: "html")

# Send a message with tracking
{:ok, sent} = Aurinko.send_message(token, %{
  to: [%{address: "[email protected]", name: "Recipient"}],
  subject: "Hello from Elixir!",
  body: "<h1>Hello!</h1>",
  body_type: "html",
  tracking: %{opens: true, thread_replies: true}
})

# Start email sync
{:ok, sync} = Aurinko.start_email_sync(token, days_within: 30)

# Fetch updated messages (initial full sync)
{:ok, page} = Aurinko.get_email_sync_updated(token, sync.sync_updated_token)

# Continue paginating
if page.next_page_token do
  {:ok, next_page} = Aurinko.get_email_sync_updated(token, page.next_page_token)
end

# Next incremental sync — reuse the delta token
{:ok, incremental} = Aurinko.get_email_sync_updated(token, page.next_delta_token)
```

---

## Calendar API

```elixir
# List all calendars
{:ok, calendars} = Aurinko.list_calendars(token)

# Get the primary calendar
{:ok, cal} = Aurinko.get_calendar(token, "primary")

# List events in a range
{:ok, page} = Aurinko.list_events(token, "primary",
  time_min: ~U[2024-01-01 00:00:00Z],
  time_max: ~U[2024-12-31 23:59:59Z]
)

# Create an event
{:ok, event} = Aurinko.create_event(token, "primary", %{
  subject: "Product Review",
  start: %{date_time: ~U[2024-06-15 14:00:00Z], timezone: "America/New_York"},
  end:   %{date_time: ~U[2024-06-15 15:00:00Z], timezone: "America/New_York"},
  location: "Zoom",
  attendees: [
    %{email: "[email protected]", name: "Alice"},
    %{email: "[email protected]", name: "Bob"}
  ],
  body: "Please review the Q2 metrics."
})

# Update an event
{:ok, updated} = Aurinko.update_event(token, "primary", event.id, %{
  subject: "Product Review — Updated",
  location: "Google Meet"
}, notify_attendees: true)

# Delete an event
:ok = Aurinko.delete_event(token, "primary", event.id)

# Check free/busy
{:ok, schedule} = Aurinko.free_busy(token, "primary", %{
  time_min: ~U[2024-06-15 09:00:00Z],
  time_max: ~U[2024-06-15 18:00:00Z]
})

# Calendar sync
{:ok, sync} = Aurinko.start_calendar_sync(token, "primary",
  time_min: ~U[2024-01-01 00:00:00Z],
  time_max: ~U[2024-12-31 23:59:59Z]
)
{:ok, page} = Aurinko.APIs.Calendar.sync_updated(token, "primary", sync.sync_updated_token)
```

---

## Contacts API

```elixir
{:ok, page} = Aurinko.list_contacts(token, limit: 50)
{:ok, contact} = Aurinko.get_contact(token, "contact_id")

{:ok, new_contact} = Aurinko.create_contact(token, %{
  given_name: "Jane",
  surname: "Doe",
  email_addresses: [%{address: "[email protected]"}],
  company: "Acme Corp"
})

:ok = Aurinko.delete_contact(token, contact.id)
```

---

## Tasks API

```elixir
{:ok, lists} = Aurinko.list_task_lists(token)
{:ok, page} = Aurinko.list_tasks(token, "task_list_id")

{:ok, task} = Aurinko.create_task(token, "task_list_id", %{
  title: "Review PR #42",
  importance: "high",
  due: ~U[2024-06-20 17:00:00Z]
})

:ok = Aurinko.delete_task(token, "task_list_id", task.id)
```

---

## Webhooks

```elixir
{:ok, sub} = Aurinko.create_subscription(token, %{
  resource: "email",
  notification_url: "https://yourapp.com/webhooks/aurinko"
})

:ok = Aurinko.delete_subscription(token, sub["id"])
```

---

## Telemetry

Aurinko emits telemetry events for every HTTP request:

| Event | Measurements | Metadata |
|---|---|---|
| `[:aurinko_ex, :request, :start]` | `system_time` | `method`, `path` |
| `[:aurinko_ex, :request, :stop]` | `duration` | `method`, `path`, `result` |
| `[:aurinko_ex, :request, :exception]` | `duration` | `method`, `path`, `kind`, `reason` |

Attach the built-in logger for development:

```elixir
Aurinko.Telemetry.attach_default_logger(:debug)
```

Or attach your own handler:

```elixir
:telemetry.attach(
  "my-handler",
  [:aurinko_ex, :request, :stop],
  fn _event, %{duration: d}, %{method: m, path: p, result: r}, _cfg ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.info("Aurinko #{m} #{p} → #{r} (#{ms}ms)")
  end,
  nil
)
```

---

## Error Handling

All functions return `{:ok, result}` or `{:error, %Aurinko.Error{}}`.

```elixir
case Aurinko.get_message(token, "msg_123") do
  {:ok, message} ->
    IO.inspect(message)

  {:error, %Aurinko.Error{type: :not_found}} ->
    Logger.warning("Message not found")

  {:error, %Aurinko.Error{type: :rate_limited}} ->
    Logger.warning("Rate limited — backing off")

  {:error, %Aurinko.Error{type: :auth_error, message: msg}} ->
    Logger.error("Auth failure: #{msg}")

  {:error, %Aurinko.Error{type: :network_error}} ->
    Logger.error("Network failure")
end
```

Error types: `:auth_error`, `:not_found`, `:rate_limited`, `:server_error`, `:network_error`, `:timeout`, `:invalid_params`, `:config_error`, `:unknown`

---

## Development

```bash
mix setup         # Install deps
mix lint          # Format check + Credo + Dialyzer
mix test          # Run tests
mix coveralls.html  # Coverage report
mix docs          # Generate ExDoc
```

---

## License

MIT — see [LICENSE](LICENSE).
