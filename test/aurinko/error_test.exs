defmodule Aurinko.ErrorTest do
  use ExUnit.Case, async: true

  alias Aurinko.Error

  describe "from_response/3" do
    test "maps 401 to :auth_error" do
      err = Error.from_response(401, %{"message" => "Unauthorized"})
      assert err.type == :auth_error
      assert err.status == 401
    end

    test "maps 404 to :not_found" do
      err = Error.from_response(404, %{"message" => "Not found"})
      assert err.type == :not_found
    end

    test "maps 429 to :rate_limited" do
      err = Error.from_response(429, %{"message" => "Too many requests"})
      assert err.type == :rate_limited
    end

    test "maps 500 to :server_error" do
      err = Error.from_response(500, %{"message" => "Internal Server Error"})
      assert err.type == :server_error
    end

    test "extracts message from response body" do
      err = Error.from_response(400, %{"message" => "Bad param"})
      assert err.message == "Bad param"
    end

    test "extracts nested error message" do
      err = Error.from_response(400, %{"error" => %{"message" => "Nested error"}})
      assert err.message == "Nested error"
    end

    test "handles plain string bodies" do
      err = Error.from_response(503, "Service Unavailable")
      assert err.message == "Service Unavailable"
    end

    test "handles empty/unknown bodies" do
      err = Error.from_response(418, %{})
      assert err.message == "An unexpected error occurred"
    end

    test "includes request_id when provided" do
      err = Error.from_response(500, %{"message" => "Oops"}, "req-abc-123")
      assert err.request_id == "req-abc-123"
    end
  end

  describe "network_error/1" do
    test "creates a network error from a string" do
      err = Error.network_error("connection refused")
      assert err.type == :network_error
      assert err.message == "connection refused"
      assert err.status == nil
    end

    test "creates a network error from an exception" do
      err = Error.network_error(%RuntimeError{message: "socket closed"})
      assert err.type == :network_error
      assert err.message == "socket closed"
    end
  end

  describe "invalid_params/1" do
    test "creates a param validation error" do
      err = Error.invalid_params("`:to` is required")
      assert err.type == :invalid_params
      assert err.message == "`:to` is required"
    end
  end

  describe "Exception.message/1" do
    test "formats message with type and message" do
      err = Error.from_response(404, %{"message" => "Email not found"})
      assert Exception.message(err) == "[not_found] HTTP 404: Email not found"
    end

    test "formats message without status" do
      err = Error.network_error("timeout")
      assert Exception.message(err) == "[network_error] timeout"
    end
  end
end
