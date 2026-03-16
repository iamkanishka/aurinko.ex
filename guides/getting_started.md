# Getting Started with Aurinko

This guide walks you through setting up Aurinko in your Elixir application from scratch.

## Prerequisites

- Elixir ~> 1.18
- An [Aurinko account](https://app.aurinko.io) with developer API keys

## 1. Install

```elixir
# mix.exs
defp deps do
  [{:aurinko, "~> 0.1"}]
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

### Handle the callback

```elixir
# In your callback controller action:
def callback(conn, %{"code" => code}) do
  {:ok, %{token: token, email: email}} = Aurinko.Auth.exchange_code(code)

  # Store `token` in your database or session
  conn
  |> put_session(:aurinko_token, token)
  |> redirect(to: "/dashboard")
end
```

## 4. Make API Calls

```elixir
token = get_session(conn, :aurinko_token)

# Read emails
{:ok, page} = Aurinko.list_messages(token, limit: 10, q: "is:unread")

# Read calendar events
{:ok, events} = Aurinko.list_events(token, "primary",
  time_min: DateTime.utc_now(),
  time_max: DateTime.add(DateTime.utc_now(), 7, :day)
)
```

## 5. Implement Sync (recommended for production)

```elixir
defmodule MyApp.EmailSync do
  def sync(token) do
    # Start or resume sync
    {:ok, sync} = Aurinko.start_email_sync(token, days_within: 30)

    if sync.ready do
      load_all_updated(token, sync.sync_updated_token)
    else
      # Try again shortly — sync is initializing
      {:retry}
    end
  end

  defp load_all_updated(token, token_or_page_token, acc \\ []) do
    {:ok, page} = Aurinko.get_email_sync_updated(token, token_or_page_token)

    messages = acc ++ page.records

    cond do
      page.next_page_token ->
        # More pages — continue
        load_all_updated(token, page.next_page_token, messages)

      page.next_delta_token ->
        # Done — persist delta token for next incremental sync
        MyApp.Store.save_delta_token(page.next_delta_token)
        {:ok, messages}
    end
  end
end
```

## 6. Enable Telemetry (optional)

```elixir
# In your Application.start/2:
Aurinko.Telemetry.attach_default_logger(:info)
```

Or integrate with your metrics system:

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
