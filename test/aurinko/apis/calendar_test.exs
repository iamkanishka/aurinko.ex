defmodule Aurinko.API.CalendarTest do
  use ExUnit.Case, async: true

  alias Aurinko.API.Calendar, as: CalendarAPI
  alias Aurinko.Error
  alias Aurinko.Types.{Calendar, CalendarEvent}

  import Aurinko.Test.Support

  describe "Calendar.from_response/1" do
    test "parses a primary calendar" do
      raw = calendar_fixture()

      calendar = Calendar.from_response(raw)

      assert calendar.id == "cal_primary"
      assert calendar.name == "My Calendar"
      assert calendar.is_primary == true
      assert calendar.time_zone == "America/New_York"
      assert calendar.access_role == "owner"
    end

    test "handles missing optional fields" do
      raw = %{"id" => "cal_xyz"}

      calendar = Calendar.from_response(raw)

      assert calendar.id == "cal_xyz"
      assert calendar.is_primary == false
      assert calendar.name == nil
    end
  end

  describe "CalendarEvent.from_response/1" do
    test "parses a full event" do
      raw = event_fixture()

      event = CalendarEvent.from_response(raw)

      assert event.subject == "Team Meeting"
      assert event.location == "Conference Room A"
      assert event.is_all_day == false
      assert event.is_recurring == false
      assert event.start.timezone == "UTC"
      assert %DateTime{} = event.start.date_time
      assert length(event.attendees) == 1
      assert hd(event.attendees).email == "[email protected]"
    end

    test "handles events with no attendees" do
      raw = event_fixture(%{"meetingInfo" => nil})

      event = CalendarEvent.from_response(raw)

      assert event.attendees == []
    end

    test "handles all-day events" do
      raw = event_fixture(%{"isAllDay" => true})

      event = CalendarEvent.from_response(raw)

      assert event.is_all_day == true
    end
  end

  describe "create_event/4 input validation" do
    test "returns error when required fields are missing" do
      result = CalendarAPI.create_event("token", "primary", %{subject: "Missing times"})

      assert {:error, %Error{type: :invalid_params}} = result
    end
  end
end
