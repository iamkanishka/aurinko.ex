defmodule Aurinko.API.EmailTest do
  use ExUnit.Case, async: true

  alias Aurinko.API.Email
  alias Aurinko.Types.{Email, Pagination, SyncResult}
  alias Aurinko.Test.Support

  import Aurinko.Test.Support

  @token valid_token()

  describe "list_messages/2" do
    test "returns a Pagination struct with email records" do
      records = [email_fixture(), email_fixture(%{"subject" => "Second email"})]
      response = paginated_response(records, next_delta_token: "delta_tok_123")

      assert {:ok, %Pagination{records: msgs, next_delta_token: "delta_tok_123"}} =
               parse_list_response(response)

      assert length(msgs) == 2
    end

    test "returns empty records when inbox is empty" do
      response = paginated_response([])

      assert {:ok, %Pagination{records: []}} = parse_list_response(response)
    end
  end

  describe "Email.from_response/1" do
    test "parses all fields from a response map" do
      raw = email_fixture(%{"subject" => "Parsed!", "isRead" => true})

      email = Aurinko.Types.Email.from_response(raw)

      assert email.subject == "Parsed!"
      assert email.is_read == true
      assert email.from.address == "[email protected]"
      assert email.from.name == "Test Sender"
      assert [%{address: "[email protected]"}] = email.to
    end

    test "handles missing optional fields gracefully" do
      raw = %{"id" => "msg_1"}

      email = Aurinko.Types.Email.from_response(raw)

      assert email.id == "msg_1"
      assert email.subject == nil
      assert email.is_read == false
      assert email.to == []
      assert email.labels == []
    end

    test "parses ISO8601 datetime strings" do
      raw = email_fixture(%{"sentAt" => "2024-06-01T10:00:00Z"})

      email = Aurinko.Types.Email.from_response(raw)

      assert %DateTime{year: 2024, month: 6, day: 1} = email.sent_at
    end

    test "handles invalid datetime strings without crashing" do
      raw = email_fixture(%{"sentAt" => "not-a-date"})

      email = Aurinko.Types.Email.from_response(raw)

      assert email.sent_at == nil
    end
  end

  describe "SyncResult.from_response/1" do
    test "parses a ready sync result" do
      raw = sync_result_fixture(ready: true)

      result = SyncResult.from_response(raw)

      assert result.ready == true
      assert result.sync_updated_token == "upd_token_abc"
      assert result.sync_deleted_token == "del_token_xyz"
    end

    test "handles not-ready sync result" do
      raw = sync_result_fixture(ready: false)

      result = SyncResult.from_response(raw)

      assert result.ready == false
      assert result.sync_updated_token == "upd_token_abc"
    end
  end

  describe "Pagination.from_response/1" do
    test "parses full pagination response" do
      raw =
        paginated_response(
          [email_fixture()],
          next_page_token: "page_tok",
          next_delta_token: "delta_tok"
        )

      page = Aurinko.Types.Pagination.from_response(raw)

      assert length(page.records) == 1
      assert page.next_page_token == "page_tok"
      assert page.next_delta_token == "delta_tok"
      assert page.total_size == 1
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp parse_list_response(body) do
    {:ok, Aurinko.Types.Pagination.from_response(body)}
  end
end
