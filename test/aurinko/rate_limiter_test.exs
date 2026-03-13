defmodule Aurinko.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Aurinko.RateLimiter

  setup do
    Application.put_env(:aurinko, :rate_limiter_enabled, true)
    Application.put_env(:aurinko, :rate_limit_per_token, 100)
    Application.put_env(:aurinko, :rate_limit_global, 1_000)
    Application.put_env(:aurinko, :rate_limit_burst, 10)

    token = "test_token_#{:rand.uniform(999_999)}"
    RateLimiter.reset_token(token)
    {:ok, token: token}
  end

  describe "check_rate/1" do
    test "returns :ok for requests within the rate limit", %{token: token} do
      # With burst of 10, first 10 calls should be immediate
      results = for _ <- 1..5, do: RateLimiter.check_rate(token)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "returns {:wait, ms} when burst is exhausted", %{token: _} do
      # Set a very low limit so we can exhaust it
      Application.put_env(:aurinko, :rate_limit_per_token, 1)
      Application.put_env(:aurinko, :rate_limit_burst, 0)

      token = "exhausted_#{:rand.uniform(999_999)}"

      # First request uses the single token
      first = RateLimiter.check_rate(token)
      assert first == :ok

      # Second should wait
      second = RateLimiter.check_rate(token)
      assert match?({:wait, _}, second)

      {:wait, ms} = second
      assert ms > 0
      assert ms < 5_000
    after
      Application.put_env(:aurinko, :rate_limit_per_token, 100)
      Application.put_env(:aurinko, :rate_limit_burst, 10)
    end

    test "different tokens have independent buckets" do
      Application.put_env(:aurinko, :rate_limit_per_token, 2)
      Application.put_env(:aurinko, :rate_limit_burst, 0)

      token_a = "token_a_#{:rand.uniform(999_999)}"
      token_b = "token_b_#{:rand.uniform(999_999)}"

      # Exhaust token_a
      RateLimiter.check_rate(token_a)
      RateLimiter.check_rate(token_a)

      # token_b should still be fine
      assert :ok = RateLimiter.check_rate(token_b)
    after
      Application.put_env(:aurinko, :rate_limit_per_token, 100)
      Application.put_env(:aurinko, :rate_limit_burst, 10)
    end
  end

  describe "disabled rate limiter" do
    test "always returns :ok when disabled", %{token: token} do
      Application.put_env(:aurinko, :rate_limiter_enabled, false)

      results = for _ <- 1..100, do: RateLimiter.check_rate(token)
      assert Enum.all?(results, &(&1 == :ok))
    after
      Application.put_env(:aurinko, :rate_limiter_enabled, true)
    end
  end

  describe "reset_token/1" do
    test "resets bucket to full capacity", %{token: token} do
      # This does not crash
      assert :ok = RateLimiter.reset_token(token)
      assert :ok = RateLimiter.check_rate(token)
    end
  end

  describe "inspect_bucket/1" do
    test "returns nil for an unseen token" do
      assert nil == RateLimiter.inspect_bucket("unseen_token_xyz")
    end

    test "returns bucket info after a request", %{token: token} do
      RateLimiter.check_rate(token)
      bucket = RateLimiter.inspect_bucket(token)

      assert is_map(bucket)
      assert Map.has_key?(bucket, :tokens)
      assert Map.has_key?(bucket, :rate)
      assert Map.has_key?(bucket, :capacity)
    end
  end
end
