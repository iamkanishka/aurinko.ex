defmodule Aurinko.Types do
  @moduledoc "Shared type definitions for Aurinko."
end

defmodule Aurinko.Types.Pagination do
  @moduledoc """
  Represents a paginated API response with delta sync tokens.
  """

  @type t :: %__MODULE__{
          records: list(map()),
          next_page_token: String.t() | nil,
          next_delta_token: String.t() | nil,
          total_size: integer() | nil
        }

  defstruct [:records, :next_page_token, :next_delta_token, :total_size]

  @doc "Parse a raw Aurinko paged response body into a Pagination struct."
  @spec from_response(map()) :: t()
  def from_response(%{} = body) do
    %__MODULE__{
      records: body["records"] || body["items"] || [],
      next_page_token: body["nextPageToken"],
      next_delta_token: body["nextDeltaToken"],
      total_size: body["totalSize"]
    }
  end
end

defmodule Aurinko.Types.SyncResult do
  @moduledoc """
  Result of a sync start operation.
  """

  @type t :: %__MODULE__{
          ready: boolean(),
          sync_updated_token: String.t() | nil,
          sync_deleted_token: String.t() | nil
        }

  defstruct [:ready, :sync_updated_token, :sync_deleted_token]

  @spec from_response(map()) :: t()
  def from_response(%{} = body) do
    %__MODULE__{
      ready: body["ready"] || false,
      sync_updated_token: body["syncUpdatedToken"],
      sync_deleted_token: body["syncDeletedToken"]
    }
  end
end

defmodule Aurinko.Types.Email do
  @moduledoc "Represents an Aurinko email message."

  @type address :: %{name: String.t() | nil, address: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          internet_message_id: String.t() | nil,
          subject: String.t() | nil,
          body: String.t() | nil,
          body_type: String.t() | nil,
          snippet: String.t() | nil,
          from: address() | nil,
          to: list(address()),
          cc: list(address()),
          bcc: list(address()),
          sent_at: DateTime.t() | nil,
          received_at: DateTime.t() | nil,
          is_read: boolean(),
          is_flagged: boolean(),
          thread_id: String.t() | nil,
          folder_id: String.t() | nil,
          has_attachments: boolean(),
          labels: list(String.t())
        }

  defstruct [
    :id,
    :internet_message_id,
    :subject,
    :body,
    :body_type,
    :snippet,
    :from,
    :sent_at,
    :received_at,
    :thread_id,
    :folder_id,
    to: [],
    cc: [],
    bcc: [],
    is_read: false,
    is_flagged: false,
    has_attachments: false,
    labels: []
  ]

  @spec from_response(map()) :: t()
  def from_response(%{} = m) do
    %__MODULE__{
      id: m["id"],
      internet_message_id: m["internetMessageId"],
      subject: m["subject"],
      body: m["body"],
      body_type: m["bodyType"],
      snippet: m["snippet"],
      from: parse_address(m["from"]),
      to: parse_addresses(m["to"]),
      cc: parse_addresses(m["cc"]),
      bcc: parse_addresses(m["bcc"]),
      sent_at: parse_datetime(m["sentAt"] || m["date"]),
      received_at: parse_datetime(m["receivedAt"]),
      is_read: m["isRead"] || false,
      is_flagged: m["isFlagged"] || false,
      thread_id: m["threadId"],
      folder_id: m["folderId"],
      has_attachments: m["hasAttachments"] || false,
      labels: m["labels"] || []
    }
  end

  defp parse_address(nil), do: nil
  defp parse_address(%{"address" => addr} = a), do: %{name: a["name"], address: addr}

  defp parse_addresses(nil), do: []
  defp parse_addresses(list) when is_list(list), do: Enum.map(list, &parse_address/1)

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

defmodule Aurinko.Types.Calendar do
  @moduledoc "Represents an Aurinko calendar."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          time_zone: String.t() | nil,
          is_primary: boolean(),
          access_role: String.t() | nil,
          color: String.t() | nil
        }

  defstruct [:id, :name, :description, :time_zone, :access_role, :color, is_primary: false]

  @spec from_response(map()) :: t()
  def from_response(%{} = c) do
    %__MODULE__{
      id: c["id"],
      name: c["name"],
      description: c["description"],
      time_zone: c["timeZone"],
      is_primary: c["isPrimary"] || false,
      access_role: c["accessRole"],
      color: c["color"]
    }
  end
end

defmodule Aurinko.Types.CalendarEvent do
  @moduledoc "Represents an Aurinko calendar event."

  @type date_time_tz :: %{date_time: DateTime.t() | nil, timezone: String.t() | nil}
  @type attendee :: %{
          email: String.t(),
          name: String.t() | nil,
          response_status: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          subject: String.t() | nil,
          body: String.t() | nil,
          location: String.t() | nil,
          start: date_time_tz() | nil,
          end: date_time_tz() | nil,
          attendees: list(attendee()),
          organizer: map() | nil,
          is_all_day: boolean(),
          is_recurring: boolean(),
          recurrence: list(String.t()),
          status: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :subject,
    :body,
    :location,
    :start,
    :end,
    :organizer,
    :status,
    :created_at,
    :updated_at,
    attendees: [],
    is_all_day: false,
    is_recurring: false,
    recurrence: []
  ]

  @spec from_response(map()) :: t()
  def from_response(%{} = e) do
    %__MODULE__{
      id: e["id"],
      subject: e["subject"],
      body: e["body"],
      location: e["location"],
      start: parse_dt_tz(e["start"]),
      end: parse_dt_tz(e["end"]),
      attendees: parse_attendees(e["meetingInfo"]),
      organizer: e["organizer"],
      is_all_day: e["isAllDay"] || false,
      is_recurring: e["isRecurring"] || false,
      recurrence: e["recurrence"] || [],
      status: e["status"],
      created_at: parse_datetime(e["createdDateTime"]),
      updated_at: parse_datetime(e["lastModifiedDateTime"])
    }
  end

  defp parse_dt_tz(nil), do: nil

  defp parse_dt_tz(%{} = dt) do
    %{
      date_time: parse_datetime(dt["dateTime"]),
      timezone: dt["timezone"] || dt["timeZone"]
    }
  end

  defp parse_attendees(nil), do: []

  defp parse_attendees(%{"attendees" => attendees}) when is_list(attendees) do
    Enum.map(attendees, fn a ->
      addr = a["emailAddress"] || %{}
      %{email: addr["address"], name: addr["name"], response_status: a["status"]}
    end)
  end

  defp parse_attendees(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

defmodule Aurinko.Types.Contact do
  @moduledoc "Represents an Aurinko contact."

  @type t :: %__MODULE__{
          id: String.t(),
          given_name: String.t() | nil,
          surname: String.t() | nil,
          display_name: String.t() | nil,
          email_addresses: list(map()),
          phone_numbers: list(map()),
          company: String.t() | nil,
          job_title: String.t() | nil
        }

  defstruct [
    :id,
    :given_name,
    :surname,
    :display_name,
    :company,
    :job_title,
    email_addresses: [],
    phone_numbers: []
  ]

  @spec from_response(map()) :: t()
  def from_response(%{} = c) do
    %__MODULE__{
      id: c["id"],
      given_name: c["givenName"],
      surname: c["surname"],
      display_name: c["displayName"],
      email_addresses: c["emailAddresses"] || [],
      phone_numbers: c["phones"] || c["phoneNumbers"] || [],
      company: c["companyName"],
      job_title: c["jobTitle"]
    }
  end
end

defmodule Aurinko.Types.Task do
  @moduledoc "Represents an Aurinko task."

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          body: String.t() | nil,
          status: String.t() | nil,
          importance: String.t() | nil,
          due: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :title,
    :body,
    :status,
    :importance,
    :due,
    :completed_at,
    :created_at,
    :updated_at
  ]

  @spec from_response(map()) :: t()
  def from_response(%{} = t) do
    %__MODULE__{
      id: t["id"],
      title: t["title"],
      body: t["body"],
      status: t["status"],
      importance: t["importance"],
      due: parse_datetime(t["dueDateTime"] || t["due"]),
      completed_at: parse_datetime(t["completedDateTime"]),
      created_at: parse_datetime(t["createdDateTime"]),
      updated_at: parse_datetime(t["lastModifiedDateTime"])
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%{"dateTime" => dt}), do: parse_datetime(dt)

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
