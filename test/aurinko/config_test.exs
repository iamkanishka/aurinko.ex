defmodule Aurinko.ConfigTest do
  use ExUnit.Case, async: false

  alias Aurinko.Config

  setup do
    original = Application.get_all_env(:aurinko)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:aurinko, k, v) end) end)
    :ok
  end

  describe "load!/0" do
    test "loads valid config successfully" do
      Application.put_env(:aurinko, :client_id, "test_id")
      Application.put_env(:aurinko, :client_secret, "test_secret")

      config = Config.load!()

      assert config.client_id == "test_id"
      assert config.client_secret == "test_secret"
      assert config.base_url == "https://api.aurinko.io/v1"
      assert config.timeout == 30_000
      assert config.retry_attempts == 3
    end

    test "raises ConfigError when client_id is missing" do
      Application.delete_env(:aurinko, :client_id)
      Application.put_env(:aurinko, :client_secret, "secret")

      assert_raise Aurinko.ConfigError, fn -> Config.load!() end
    end

    test "raises ConfigError when client_secret is missing" do
      Application.put_env(:aurinko, :client_id, "id")
      Application.delete_env(:aurinko, :client_secret)

      assert_raise Aurinko.ConfigError, fn -> Config.load!() end
    end

    test "uses custom values when provided" do
      Application.put_env(:aurinko, :client_id, "my_id")
      Application.put_env(:aurinko, :client_secret, "my_secret")
      Application.put_env(:aurinko, :timeout, 60_000)
      Application.put_env(:aurinko, :retry_attempts, 5)

      config = Config.load!()
      assert config.timeout == 60_000
      assert config.retry_attempts == 5
    end
  end

  describe "merge/2" do
    test "merges overrides on top of base config" do
      base = %{timeout: 30_000, retry_attempts: 3, client_id: "base_id"}
      merged = Config.merge(base, timeout: 60_000)

      assert merged.timeout == 60_000
      assert merged.retry_attempts == 3
      assert merged.client_id == "base_id"
    end
  end

  describe "base_url/0" do
    test "returns configured base URL" do
      Application.put_env(:aurinko, :base_url, "https://custom.api.io/v2")
      assert Config.base_url() == "https://custom.api.io/v2"
    end

    test "returns default when not configured" do
      Application.delete_env(:aurinko, :base_url)
      assert Config.base_url() == "https://api.aurinko.io/v1"
    end
  end
end
