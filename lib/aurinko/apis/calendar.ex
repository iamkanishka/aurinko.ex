defmodule Aurinko.API.Calendar do
  @moduledoc """
  Aurinko Calendar API — calendars, events, sync, and free/busy scheduling.

  Supports Google Calendar, Outlook/Office 365, iCloud Calendar, and MS Exchange.

  ## Sync Model

  Calendar sync is per-calendar. Use `primary` as the calendar ID for the user's
  primary calendar.

      # Start sync for primary calendar
      {:ok, sync} = Aurinko.Calendar.start_sync(token, "primary",
        time_min: ~U[2024-01-01 00:00:00Z],
        time_max: ~U[2024-12-31 23:59:59Z]
      )

      # Load updated events
      {:ok, page} = Aurinko.Calendar.sync_updated(token, "primary", sync.sync_updated_token)
  """

  alias Aurinko.HTTP.Client
  alias Aurinko.Types.{Calendar, CalendarEvent, Pagination, SyncResult}
  alias Aurinko.Error

  # ── Calendars ────────────────────────────────────────────────────────────────

  @doc """
  List all calendars accessible by the authenticated account.
  """
  @spec list_calendars(String.t(), keyword()) ::
          {:ok, list(Calendar.t())} | {:error, Error.t()}
  def list_calendars(token, opts \\ []) do
    params = opts |> Keyword.take([:limit, :page_token]) |> camelize_params()

    with {:ok, body} <- Client.get(token, "/calendars", params: params) do
      calendars = (body["records"] || []) |> Enum.map(&Calendar.from_response/1)
      {:ok, calendars}
    end
  end

  @doc """
  Get a specific calendar by ID. Use `"primary"` for the user's primary calendar.
  """
  @spec get_calendar(String.t(), String.t()) ::
          {:ok, Calendar.t()} | {:error, Error.t()}
  def get_calendar(token, calendar_id) do
    with {:ok, body} <- Client.get(token, "/calendars/#{calendar_id}") do
      {:ok, Calendar.from_response(body)}
    end
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  @doc """
  List events in a calendar within a time range.

  ## Options

  - `:time_min` — Start of time range (DateTime)
  - `:time_max` — End of time range (DateTime)
  - `:limit` — Max results (default: 20)
  - `:page_token` — Pagination token
  """
  @spec list_events(String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def list_events(token, calendar_id, opts \\ []) do
    params =
      opts
      |> Keyword.take([:time_min, :time_max, :limit, :page_token])
      |> Enum.map(fn
        {:time_min, dt} -> {:timeMin, DateTime.to_iso8601(dt)}
        {:time_max, dt} -> {:timeMax, DateTime.to_iso8601(dt)}
        {k, v} -> {camelize(k), v}
      end)

    with {:ok, body} <-
           Client.post(token, "/calendars/#{calendar_id}/events/range", nil, params: params) do
      {:ok, Pagination.from_response(body)}
    end
  end

  @doc """
  Get a specific event by ID.
  """
  @spec get_event(String.t(), String.t(), String.t()) ::
          {:ok, CalendarEvent.t()} | {:error, Error.t()}
  def get_event(token, calendar_id, event_id) do
    with {:ok, body} <- Client.get(token, "/calendars/#{calendar_id}/events/#{event_id}") do
      {:ok, CalendarEvent.from_response(body)}
    end
  end

  @doc """
  Create a new calendar event.

  ## Parameters

  - `:subject` — Event title (required)
  - `:start` — Start time map with `:date_time` and `:timezone` (required)
  - `:end` — End time map with `:date_time` and `:timezone` (required)
  - `:body` — Event description
  - `:location` — Event location string
  - `:attendees` — List of attendee maps with `:email` and optional `:name`
  - `:is_all_day` — Boolean

  ## Options

  - `:notify_attendees` — Whether to send invitations (default: true)
  - `:body_type` — `"html"` or `"text"`
  - `:return_record` — Return full event record (default: true)

  ## Examples

      {:ok, event} = Aurinko.Calendar.create_event(token, "primary", %{
        subject: "Team Meeting",
        start: %{date_time: ~U[2024-06-01 14:00:00Z], timezone: "UTC"},
        end: %{date_time: ~U[2024-06-01 15:00:00Z], timezone: "UTC"},
        attendees: [%{email: "[email protected]"}],
        location: "Conference Room A"
      })
  """
  @spec create_event(String.t(), String.t(), map(), keyword()) ::
          {:ok, CalendarEvent.t()} | {:error, Error.t()}
  def create_event(token, calendar_id, params, opts \\ [])

  def create_event(token, calendar_id, %{subject: _, start: _, end: _} = params, opts) do
    body = build_event_body(params)
    query = build_event_query(opts)

    with {:ok, resp} <-
           Client.post(token, "/calendars/#{calendar_id}/events", body, params: query) do
      {:ok, CalendarEvent.from_response(resp)}
    end
  end

  def create_event(_token, _calendar_id, _params, _opts),
    do: {:error, Error.invalid_params("`:subject`, `:start`, and `:end` are required")}

  @doc """
  Update an existing calendar event.

  ## Options

  - `:notify_attendees` — Whether to notify attendees of changes (default: true)
  """
  @spec update_event(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, CalendarEvent.t()} | {:error, Error.t()}
  def update_event(token, calendar_id, event_id, params, opts \\ []) do
    body = build_event_body(params)
    query = build_event_query(opts)

    with {:ok, resp} <-
           Client.patch(token, "/calendars/#{calendar_id}/events/#{event_id}", body,
             params: query
           ) do
      {:ok, CalendarEvent.from_response(resp)}
    end
  end

  @doc """
  Delete a calendar event.

  ## Options

  - `:notify_attendees` — Whether to notify attendees of cancellation (default: true)
  """
  @spec delete_event(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete_event(token, calendar_id, event_id, opts \\ []) do
    query = build_event_query(opts)

    with {:ok, _} <-
           Client.delete(token, "/calendars/#{calendar_id}/events/#{event_id}", params: query) do
      :ok
    end
  end

  # ── Sync ─────────────────────────────────────────────────────────────────────

  @doc """
  Start or resume a calendar sync for a given calendar.

  ## Options

  - `:time_min` — Start of sync range (DateTime)
  - `:time_max` — End of sync range (DateTime)
  - `:await_ready` — Block until ready (default: false)
  """
  @spec start_sync(String.t(), String.t(), keyword()) ::
          {:ok, SyncResult.t()} | {:error, Error.t()}
  def start_sync(token, calendar_id, opts \\ []) do
    params =
      opts
      |> Enum.map(fn
        {:time_min, dt} -> {:timeMin, DateTime.to_iso8601(dt)}
        {:time_max, dt} -> {:timeMax, DateTime.to_iso8601(dt)}
        {:await_ready, v} -> {:awaitReady, v}
        {k, v} -> {camelize(k), v}
      end)

    with {:ok, body} <- Client.post(token, "/calendars/#{calendar_id}/sync", nil, params: params) do
      {:ok, SyncResult.from_response(body)}
    end
  end

  @doc """
  Fetch updated (new/modified) calendar events since the last sync.
  """
  @spec sync_updated(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def sync_updated(token, calendar_id, delta_token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:page_token])
      |> Keyword.put(:delta_token, delta_token)
      |> camelize_params()

    with {:ok, body} <-
           Client.get(token, "/calendars/#{calendar_id}/sync/updated", params: params) do
      {:ok, Pagination.from_response(body)}
    end
  end

  @doc """
  Fetch deleted event IDs since the last sync.
  """
  @spec sync_deleted(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def sync_deleted(token, calendar_id, delta_token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:page_token])
      |> Keyword.put(:delta_token, delta_token)
      |> camelize_params()

    with {:ok, body} <-
           Client.get(token, "/calendars/#{calendar_id}/sync/deleted", params: params) do
      {:ok, Pagination.from_response(body)}
    end
  end

  # ── Free/Busy ────────────────────────────────────────────────────────────────

  @doc """
  Check free/busy availability for a calendar in a given time range.

  ## Parameters

  - `:time_min` — Start of range (DateTime, required)
  - `:time_max` — End of range (DateTime, required)
  """
  @spec free_busy(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def free_busy(token, calendar_id, %{time_min: time_min, time_max: time_max} = _params) do
    body = %{
      timeMin: DateTime.to_iso8601(time_min),
      timeMax: DateTime.to_iso8601(time_max)
    }

    Client.post(token, "/calendars/#{calendar_id}/freeBusy", body)
  end

  def free_busy(_token, _calendar_id, _),
    do: {:error, Error.invalid_params("`:time_min` and `:time_max` are required")}

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp build_event_body(params) do
    %{}
    |> maybe_put(:subject, params[:subject])
    |> maybe_put(:body, params[:body])
    |> maybe_put(:location, params[:location])
    |> maybe_put(:start, format_datetime_tz(params[:start]))
    |> maybe_put(:end, format_datetime_tz(params[:end]))
    |> maybe_put(:meetingInfo, format_meeting_info(params[:attendees]))
    |> maybe_put(:isAllDay, params[:is_all_day])
    |> maybe_put(:recurrence, params[:recurrence])
  end

  defp build_event_query(opts) do
    Enum.flat_map(opts, fn
      {:notify_attendees, v} -> [{:notifyAttendees, v}]
      {:body_type, v} -> [{:bodyType, v}]
      {:return_record, v} -> [{:returnRecord, v}]
      _ -> []
    end)
  end

  defp format_datetime_tz(nil), do: nil

  defp format_datetime_tz(%{date_time: dt, timezone: tz}) do
    %{"dateTime" => DateTime.to_iso8601(dt), "timezone" => tz}
  end

  defp format_meeting_info(nil), do: nil

  defp format_meeting_info(attendees) when is_list(attendees) do
    %{
      "attendees" =>
        Enum.map(attendees, fn a ->
          %{
            "emailAddress" => %{"address" => a[:email] || a[:address], "name" => a[:name]},
            "type" => a[:type] || "required"
          }
        end)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp camelize_params(kw) do
    Enum.map(kw, fn {k, v} -> {camelize(k), v} end)
  end

  defp camelize(key) when is_atom(key), do: key |> Atom.to_string() |> camelize()

  defp camelize(str) when is_binary(str) do
    [first | rest] = String.split(str, "_")
    first <> Enum.map_join(rest, "", &String.capitalize/1)
  end
end
