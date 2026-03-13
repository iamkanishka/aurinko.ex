defmodule Aurinko.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Aurinko.{CircuitBreaker, Error}

  setup do
    Application.put_env(:aurinko, :circuit_breaker_enabled, true)
    Application.put_env(:aurinko, :circuit_breaker_threshold, 3)
    Application.put_env(:aurinko, :circuit_breaker_timeout, 50)

    # Use unique circuit names per test to avoid interference
    circuit = "test_circuit_#{:rand.uniform(999_999)}"
    CircuitBreaker.reset(circuit)
    {:ok, circuit: circuit}
  end

  describe "call/2 in closed state" do
    test "passes through successful results", %{circuit: circuit} do
      result = CircuitBreaker.call(circuit, fn -> {:ok, "data"} end)
      assert {:ok, "data"} = result
    end

    test "passes through non-server errors without counting failures", %{circuit: circuit} do
      result =
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :not_found, message: "Not found"}}
        end)

      assert {:error, %Error{type: :not_found}} = result
      assert %{state: :closed, failure_count: 0} = CircuitBreaker.status(circuit)
    end

    test "counts server errors as failures", %{circuit: circuit} do
      CircuitBreaker.call(circuit, fn ->
        {:error, %Error{type: :server_error, message: "500"}}
      end)

      assert %{state: :closed, failure_count: 1} = CircuitBreaker.status(circuit)
    end
  end

  describe "circuit opening" do
    test "opens after threshold failures", %{circuit: circuit} do
      for _ <- 1..3 do
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :server_error, message: "500"}}
        end)
      end

      assert %{state: :open} = CircuitBreaker.status(circuit)
    end

    test "rejects requests when open", %{circuit: circuit} do
      # Trigger opening
      for _ <- 1..3 do
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :server_error, message: "err"}}
        end)
      end

      # Next call should be rejected
      result = CircuitBreaker.call(circuit, fn -> {:ok, "data"} end)
      assert {:error, :circuit_open} = result
    end
  end

  describe "half-open and recovery" do
    test "transitions to half-open after timeout", %{circuit: circuit} do
      # Open the circuit
      for _ <- 1..3 do
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :server_error, message: "err"}}
        end)
      end

      assert %{state: :open} = CircuitBreaker.status(circuit)

      # Wait for the 50ms timeout
      Process.sleep(60)

      # Next call should probe (half-open)
      result = CircuitBreaker.call(circuit, fn -> {:ok, "probe_success"} end)
      assert {:ok, "probe_success"} = result

      # Should be closed now
      assert %{state: :closed} = CircuitBreaker.status(circuit)
    end

    test "reopens on probe failure after timeout", %{circuit: circuit} do
      # Open it
      for _ <- 1..3 do
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :server_error, message: "err"}}
        end)
      end

      Process.sleep(60)

      # Probe fails
      CircuitBreaker.call(circuit, fn ->
        {:error, %Error{type: :server_error, message: "still broken"}}
      end)

      # Should re-open
      assert %{state: :open} = CircuitBreaker.status(circuit)
    end
  end

  describe "reset/1" do
    test "resets an open circuit to closed", %{circuit: circuit} do
      for _ <- 1..3 do
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :server_error, message: "err"}}
        end)
      end

      assert %{state: :open} = CircuitBreaker.status(circuit)
      CircuitBreaker.reset(circuit)
      assert %{state: :closed, failure_count: 0} = CircuitBreaker.status(circuit)
    end
  end

  describe "disabled circuit breaker" do
    test "always passes through when disabled", %{circuit: circuit} do
      Application.put_env(:aurinko, :circuit_breaker_enabled, false)

      # Even after many failures, no circuit opens
      for _ <- 1..10 do
        CircuitBreaker.call(circuit, fn ->
          {:error, %Error{type: :server_error, message: "err"}}
        end)
      end

      result = CircuitBreaker.call(circuit, fn -> {:ok, "works"} end)
      assert {:ok, "works"} = result
    after
      Application.put_env(:aurinko, :circuit_breaker_enabled, true)
    end
  end
end
