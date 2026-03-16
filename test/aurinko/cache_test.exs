defmodule Aurinko.CacheTest do
  use ExUnit.Case, async: false

  alias Aurinko.Cache

  setup do
    # Flush cache between tests
    Cache.flush()
    Application.put_env(:aurinko, :cache_enabled, true)
    Application.put_env(:aurinko, :cache_ttl, 5_000)
    on_exit(fn -> Cache.flush() end)
    :ok
  end

  describe "get/1 and put/2" do
    test "returns nil for missing key" do
      assert nil == Cache.get("nonexistent_key")
    end

    test "returns {:ok, value} for existing key" do
      Cache.put("my_key", %{foo: "bar"})
      assert {:ok, %{foo: "bar"}} = Cache.get("my_key")
    end

    test "stores and retrieves any term" do
      Cache.put("list_key", [1, 2, 3])
      assert {:ok, [1, 2, 3]} = Cache.get("list_key")

      Cache.put("int_key", 42)
      assert {:ok, 42} = Cache.get("int_key")

      Cache.put("nil_key", nil)
      assert {:ok, nil} = Cache.get("nil_key")
    end

    test "returns nil for expired key" do
      Cache.put("expiring_key", "value", ttl: 1)
      Process.sleep(10)
      assert nil == Cache.get("expiring_key")
    end

    test "respects TTL on put" do
      Cache.put("short_ttl", "value", ttl: 50)
      assert {:ok, "value"} = Cache.get("short_ttl")
      Process.sleep(60)
      assert nil == Cache.get("short_ttl")
    end
  end

  describe "delete/1" do
    test "removes a key" do
      Cache.put("delete_me", "value")
      assert {:ok, "value"} = Cache.get("delete_me")

      Cache.delete("delete_me")
      assert nil == Cache.get("delete_me")
    end

    test "is idempotent for missing keys" do
      assert :ok = Cache.delete("never_existed")
    end
  end

  describe "build_key/3" do
    test "generates deterministic keys" do
      key1 = Cache.build_key("token_abc", "/email/messages", limit: 10)
      key2 = Cache.build_key("token_abc", "/email/messages", limit: 10)
      assert key1 == key2
    end

    test "different tokens produce different keys" do
      key1 = Cache.build_key("token_abc", "/email/messages", [])
      key2 = Cache.build_key("token_xyz", "/email/messages", [])
      refute key1 == key2
    end

    test "different paths produce different keys" do
      key1 = Cache.build_key("token_abc", "/email/messages", [])
      key2 = Cache.build_key("token_abc", "/calendars", [])
      refute key1 == key2
    end

    test "different params produce different keys" do
      key1 = Cache.build_key("token_abc", "/email/messages", limit: 10)
      key2 = Cache.build_key("token_abc", "/email/messages", limit: 50)
      refute key1 == key2
    end
  end

  describe "invalidate_token/1" do
    test "removes all entries for a token" do
      token = "test_token_123"
      key1 = Cache.build_key(token, "/email/messages", [])
      key2 = Cache.build_key(token, "/calendars", [])
      other_key = Cache.build_key("other_token", "/email/messages", [])

      Cache.put(key1, "emails")
      Cache.put(key2, "calendars")
      Cache.put(other_key, "other_emails")

      Cache.invalidate_token(token)

      assert nil == Cache.get(key1)
      assert nil == Cache.get(key2)
      assert {:ok, "other_emails"} = Cache.get(other_key)
    end
  end

  describe "flush/0" do
    test "clears all entries" do
      Cache.put("a", 1)
      Cache.put("b", 2)
      Cache.put("c", 3)

      Cache.flush()

      assert nil == Cache.get("a")
      assert nil == Cache.get("b")
      assert nil == Cache.get("c")
    end
  end

  describe "stats/0" do
    test "returns a stats map with numeric values" do
      stats = Cache.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :hits)
      assert Map.has_key?(stats, :misses)
      assert Map.has_key?(stats, :evictions)
      assert Map.has_key?(stats, :size)
    end

    test "size reflects current entry count" do
      Cache.flush()
      stats_before = Cache.stats()

      Cache.put("s1", "v1")
      Cache.put("s2", "v2")

      stats_after = Cache.stats()
      assert stats_after.size >= stats_before.size + 2
    end
  end

  describe "disabled cache" do
    test "get always returns nil when cache is disabled" do
      Application.put_env(:aurinko, :cache_enabled, false)
      key = "disabled_cache_test_#{System.unique_integer([:positive])}"
      Cache.put(key, "value")
      assert nil == Cache.get(key)
      Application.put_env(:aurinko, :cache_enabled, true)
    end

    test "put is a no-op when cache is disabled" do
      Application.put_env(:aurinko, :cache_enabled, false)
      assert :ok = Cache.put("key", "value")
      Application.put_env(:aurinko, :cache_enabled, true)
    end
  end
end
