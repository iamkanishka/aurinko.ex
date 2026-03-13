defmodule Aurinko.HTTP.ClientTest do
  use ExUnit.Case, async: false

  alias Aurinko.{Cache, Error}
  alias Aurinko.HTTP.Client

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    Application.put_env(:aurinko, :base_url, base_url)
    Application.put_env(:aurinko, :retry_attempts, 0)
    Application.put_env(:aurinko, :cache_enabled, true)
    Application.put_env(:aurinko, :circuit_breaker_enabled, false)
    Application.put_env(:aurinko, :rate_limiter_enabled, false)
    Cache.flush()

    {:ok, bypass: bypass, token: "test_bearer_token"}
  end

  describe "get/3" do
    test "returns parsed JSON body on 200", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "GET", "/v1/email/messages", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"records":[{"id":"msg1"}]}))
      end)

      assert {:ok, %{"records" => [%{"id" => "msg1"}]}} =
               Client.get(token, "/email/messages")
    end

    test "returns :auth_error on 401", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "GET", "/v1/email/messages", fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"message":"Unauthorized"}))
      end)

      assert {:error, %Error{type: :auth_error, status: 401}} =
               Client.get(token, "/email/messages")
    end

    test "returns :not_found on 404", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "GET", "/v1/email/messages/bad_id", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not found"}))
      end)

      assert {:error, %Error{type: :not_found, status: 404}} =
               Client.get(token, "/email/messages/bad_id")
    end

    test "returns :server_error on 500 (no retry configured)", %{bypass: bypass, token: token} do
      Application.put_env(:aurinko, :retry_attempts, 0)

      Bypass.expect_once(bypass, "GET", "/v1/email/messages", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"message":"Server error"}))
      end)

      assert {:error, %Error{type: :server_error, status: 500}} =
               Client.get(token, "/email/messages")
    end

    test "sends Authorization header", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "GET", "/v1/calendars", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
        assert auth == "Bearer #{token}"
        Plug.Conn.resp(conn, 200, ~s({"records":[]}))
      end)

      assert {:ok, _} = Client.get(token, "/calendars")
    end

    test "sends query parameters", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "GET", "/v1/email/messages", fn conn ->
        assert conn.query_string =~ "limit=10"
        Plug.Conn.resp(conn, 200, ~s({"records":[]}))
      end)

      Client.get(token, "/email/messages", params: [limit: 10])
    end
  end

  describe "post/4" do
    test "sends JSON body on POST", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "POST", "/v1/email/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert payload["subject"] == "Hello"
        Plug.Conn.resp(conn, 200, ~s({"id":"new_msg_id"}))
      end)

      assert {:ok, %{"id" => "new_msg_id"}} =
               Client.post(token, "/email/messages", %{subject: "Hello"})
    end
  end

  describe "delete/3" do
    test "sends DELETE request", %{bypass: bypass, token: token} do
      Bypass.expect_once(bypass, "DELETE", "/v1/email/drafts/draft_123", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({}))
      end)

      assert {:ok, _} = Client.delete(token, "/email/drafts/draft_123")
    end
  end

  describe "caching" do
    test "caches GET responses and returns on second call", %{bypass: bypass, token: token} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/v1/calendars", fn conn ->
        :counters.add(call_count, 1, 1)
        Plug.Conn.resp(conn, 200, ~s({"records":[{"id":"cal1"}]}))
      end)

      {:ok, first} = Client.get(token, "/calendars")
      {:ok, second} = Client.get(token, "/calendars")

      assert first == second
      # Only one real HTTP call
      assert :counters.get(call_count, 1) == 1
    end

    test "bypass_cache: true skips the cache", %{bypass: bypass, token: token} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/v1/calendars", fn conn ->
        :counters.add(call_count, 1, 1)
        Plug.Conn.resp(conn, 200, ~s({"records":[]}))
      end)

      Client.get(token, "/calendars")
      Client.get(token, "/calendars", bypass_cache: true)

      assert :counters.get(call_count, 1) == 2
    end

    test "POST responses are not cached", %{bypass: bypass, token: token} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/v1/email/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        Plug.Conn.resp(conn, 200, ~s({"id":"msg1"}))
      end)

      Client.post(token, "/email/messages", %{subject: "test"})
      Client.post(token, "/email/messages", %{subject: "test"})

      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "retry behaviour" do
    test "retries on 500 and succeeds", %{bypass: bypass, token: token} do
      Application.put_env(:aurinko, :retry_attempts, 2)
      Application.put_env(:aurinko, :retry_delay, 10)
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/v1/email/messages", fn conn ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if n == 0 do
          Plug.Conn.resp(conn, 500, ~s({"message":"Server error"}))
        else
          Plug.Conn.resp(conn, 200, ~s({"records":[]}))
        end
      end)

      Cache.flush()
      assert {:ok, _} = Client.get(token, "/email/messages", bypass_cache: true)
      assert :counters.get(call_count, 1) == 2
    after
      Application.put_env(:aurinko, :retry_attempts, 0)
    end

    test "respects Retry-After header on 429", %{bypass: bypass, token: token} do
      Application.put_env(:aurinko, :retry_attempts, 1)
      Application.put_env(:aurinko, :retry_delay, 10)
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/v1/email/messages", fn conn ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if n == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.resp(429, ~s({"message":"Rate limited"}))
        else
          Plug.Conn.resp(conn, 200, ~s({"records":[]}))
        end
      end)

      Cache.flush()
      assert {:ok, _} = Client.get(token, "/email/messages", bypass_cache: true)
    after
      Application.put_env(:aurinko, :retry_attempts, 0)
    end
  end

  describe "network errors" do
    test "returns network error when server is down", %{bypass: bypass, token: token} do
      Bypass.down(bypass)

      assert {:error, %Error{type: :network_error}} =
               Client.get(token, "/email/messages")
    end
  end
end
