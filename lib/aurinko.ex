defmodule Aurinko do
  @moduledoc """
  Aurinko — Production-grade Elixir client for the [Aurinko Unified Mailbox API](https://docs.aurinko.io).

  ## Overview

  Aurinko provides a unified API for Email, Calendar, Contacts, Tasks, Webhooks,
  and Booking across Google Workspace, Office 365, Outlook, MS Exchange, Zoho, and iCloud.

  ## Features

  - Full Unified API coverage (Email, Calendar, Contacts, Tasks, Webhooks, Booking)
  - ETS-backed response caching with TTL and LRU eviction (`Aurinko.Cache`)
  - Token-bucket rate limiting with per-account and global RPS caps (`Aurinko.RateLimiter`)
  - Circuit breaker with half-open probing (`Aurinko.CircuitBreaker`)
  - Automatic retry with exponential backoff + jitter
  - Lazy stream-based pagination (`Aurinko.Paginator`)
  - High-level sync orchestration (`Aurinko.Sync.Orchestrator`)
  - Webhook HMAC-SHA256 signature verification (`Aurinko.Webhook.Verifier`)
  - Telemetry events + `Telemetry.Metrics` definitions (`Aurinko.Telemetry`)
  - Typed response structs for all resources
  - NimbleOptions config validation

  ## Quick Start

      config :aurinko,
        client_id: System.get_env("AURINKO_CLIENT_ID"),
        client_secret: System.get_env("AURINKO_CLIENT_SECRET")

      # Auth
      url = Aurinko.authorize_url(service_type: "Google", scopes: ["Mail.Read"],
                                    return_url: "https://myapp.com/callback")
      {:ok, %{token: token}} = Aurinko.Auth.exchange_code(code)

      # Email
      {:ok, page} = Aurinko.list_messages(token, q: "is:unread", limit: 25)

      # Stream all pages lazily
      Aurinko.Paginator.stream(token, &Aurinko.list_messages/2)
      |> Stream.each(&process/1)
      |> Stream.run()

      # Calendar
      {:ok, event} = Aurinko.create_event(token, "primary", %{
        subject: "Standup",
        start: %{date_time: ~U[2024-06-01 09:00:00Z], timezone: "UTC"},
        end:   %{date_time: ~U[2024-06-01 09:30:00Z], timezone: "UTC"}
      })
  """

  alias Aurinko.API.{Booking, Calendar, Contacts, Email, Tasks, Webhooks}
  alias Aurinko.Auth

  # ── Auth ─────────────────────────────────────────────────────────────────────

  defdelegate authorize_url(opts \\ []), to: Auth
  defdelegate exchange_code(code, opts \\ []), to: Auth
  defdelegate refresh_token(refresh_token, opts \\ []), to: Auth

  # ── Email ─────────────────────────────────────────────────────────────────────

  defdelegate list_messages(token, opts \\ []), to: Email
  defdelegate get_message(token, id, opts \\ []), to: Email
  defdelegate send_message(token, params), to: Email
  defdelegate update_message(token, id, params), to: Email
  defdelegate create_draft(token, params), to: Email
  defdelegate delete_draft(token, id), to: Email
  defdelegate list_attachments(token, message_id), to: Email
  defdelegate get_attachment(token, message_id, attachment_id), to: Email
  defdelegate start_email_sync(token, opts \\ []), to: Email, as: :start_sync
  defdelegate get_email_sync_updated(token, delta_token, opts \\ []), to: Email, as: :sync_updated
  defdelegate get_email_sync_deleted(token, delta_token, opts \\ []), to: Email, as: :sync_deleted

  # ── Calendar ─────────────────────────────────────────────────────────────────

  defdelegate list_calendars(token, opts \\ []), to: Calendar
  defdelegate get_calendar(token, calendar_id), to: Calendar
  defdelegate list_events(token, calendar_id, opts \\ []), to: Calendar
  defdelegate get_event(token, calendar_id, event_id), to: Calendar
  defdelegate create_event(token, calendar_id, params, opts \\ []), to: Calendar
  defdelegate update_event(token, calendar_id, event_id, params, opts \\ []), to: Calendar
  defdelegate delete_event(token, calendar_id, event_id, opts \\ []), to: Calendar
  defdelegate free_busy(token, calendar_id, params), to: Calendar
  defdelegate start_calendar_sync(token, calendar_id, opts \\ []), to: Calendar, as: :start_sync

  # ── Contacts ─────────────────────────────────────────────────────────────────

  defdelegate list_contacts(token, opts \\ []), to: Contacts
  defdelegate get_contact(token, id), to: Contacts
  defdelegate create_contact(token, params), to: Contacts
  defdelegate update_contact(token, id, params), to: Contacts
  defdelegate delete_contact(token, id), to: Contacts
  defdelegate start_contacts_sync(token, opts \\ []), to: Contacts, as: :start_sync

  # ── Tasks ─────────────────────────────────────────────────────────────────────

  defdelegate list_task_lists(token, opts \\ []), to: Tasks
  defdelegate list_tasks(token, task_list_id, opts \\ []), to: Tasks
  defdelegate create_task(token, task_list_id, params), to: Tasks
  defdelegate update_task(token, task_list_id, task_id, params), to: Tasks
  defdelegate delete_task(token, task_list_id, task_id), to: Tasks

  # ── Webhooks ─────────────────────────────────────────────────────────────────

  defdelegate list_subscriptions(token, opts \\ []), to: Webhooks
  defdelegate create_subscription(token, params), to: Webhooks
  defdelegate delete_subscription(token, id), to: Webhooks

  # ── Booking ─────────────────────────────────────────────────────────────────

  defdelegate list_booking_profiles(token, opts \\ []), to: Booking
  defdelegate get_booking_availability(token, profile_id, params), to: Booking
end
