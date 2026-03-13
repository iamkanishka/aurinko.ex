defmodule Aurinko.Test.Support do
  @moduledoc "Test helpers and fixtures for Aurinko."

  @valid_token "test_access_token_abc123"

  def valid_token, do: @valid_token

  def email_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "msg_#{:rand.uniform(99_999)}",
        "subject" => "Test Email",
        "from" => %{"address" => "[email protected]", "name" => "Test Sender"},
        "to" => [%{"address" => "[email protected]"}],
        "body" => "Hello, world!",
        "bodyType" => "text",
        "isRead" => false,
        "isFlagged" => false,
        "hasAttachments" => false,
        "sentAt" => "2024-06-01T10:00:00Z",
        "labels" => []
      },
      overrides
    )
  end

  def calendar_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "cal_primary",
        "name" => "My Calendar",
        "isPrimary" => true,
        "timeZone" => "America/New_York",
        "accessRole" => "owner"
      },
      overrides
    )
  end

  def event_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "evt_#{:rand.uniform(99_999)}",
        "subject" => "Team Meeting",
        "body" => "Agenda TBD",
        "location" => "Conference Room A",
        "start" => %{"dateTime" => "2024-06-01T14:00:00Z", "timezone" => "UTC"},
        "end" => %{"dateTime" => "2024-06-01T15:00:00Z", "timezone" => "UTC"},
        "isAllDay" => false,
        "isRecurring" => false,
        "meetingInfo" => %{
          "attendees" => [
            %{
              "emailAddress" => %{"address" => "[email protected]"},
              "type" => "required",
              "status" => "accepted"
            }
          ]
        }
      },
      overrides
    )
  end

  def contact_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "contact_#{:rand.uniform(99_999)}",
        "givenName" => "Jane",
        "surname" => "Smith",
        "displayName" => "Jane Smith",
        "emailAddresses" => [%{"address" => "[email protected]"}],
        "phones" => []
      },
      overrides
    )
  end

  def task_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "task_#{:rand.uniform(99_999)}",
        "title" => "Write tests",
        "status" => "notStarted",
        "importance" => "normal"
      },
      overrides
    )
  end

  def sync_result_fixture(opts \\ []) do
    %{
      "ready" => Keyword.get(opts, :ready, true),
      "syncUpdatedToken" => "upd_token_abc",
      "syncDeletedToken" => "del_token_xyz"
    }
  end

  def paginated_response(records, opts \\ []) do
    %{
      "records" => records,
      "nextPageToken" => Keyword.get(opts, :next_page_token),
      "nextDeltaToken" => Keyword.get(opts, :next_delta_token),
      "totalSize" => length(records)
    }
  end
end
