defmodule Aurinko.CircuitBreaker do
  @moduledoc """
  Per-endpoint circuit breaker with three states: closed, open, and half-open.

  Protects downstream Aurinko API endpoints from cascading failures.

  ## States

  - **Closed** — Normal operation. Requests flow through.
  - **Open** — Too many failures. Requests are rejected immediately without hitting the API.
  - **Half-open** — Cooldown expired. A single probe request is allowed through.
    If it succeeds, the circuit closes. If it fails, the circuit reopens.

  ## Configuration

      config :aurinko_ex,
        circuit_breaker_enabled: true,
        circuit_breaker_threshold: 5,       # failures before opening
        circuit_breaker_timeout: 30_000,    # ms before transitioning to half-open
        circuit_breaker_window: 60_000      # rolling window for failure counting (ms)

  ## Usage

      Aurinko.CircuitBreaker.call("email.list", fn -> make_request() end)
  """

  use GenServer

  require Logger

  @default_threshold 5
  @default_timeout 30_000

  @type circuit_name :: String.t()
  @type state_name :: :closed | :open | :half_open
  @type circuit_state :: %{
          name: circuit_name(),
          state: state_name(),
          failure_count: non_neg_integer(),
          last_failure_at: integer() | nil,
          opened_at: integer() | nil,
          success_count: non_neg_integer()
        }

  # ── Lifecycle ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:aurinko_circuits, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{table: table}}
  end

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Execute `fun` through the named circuit breaker.

  Returns `{:error, :circuit_open}` if the circuit is open and the request
  should not be attempted.

  ## Examples

      Aurinko.CircuitBreaker.call("aurinko.email", fn ->
        Req.get("https://api.aurinko.io/v1/email/messages")
      end)
  """
  @spec call(circuit_name(), (-> result)) :: result | {:error, :circuit_open}
        when result: term()
  def call(name, fun) when is_binary(name) and is_function(fun, 0) do
    if enabled?() do
      case check_state(name) do
        :allow ->
          execute(name, fun)

        :reject ->
          Logger.warning("[Aurinko.CircuitBreaker] Circuit '#{name}' is OPEN — rejecting request")

          :telemetry.execute(
            [:aurinko_ex, :circuit_breaker, :rejected],
            %{count: 1},
            %{circuit: name}
          )

          {:error, :circuit_open}
      end
    else
      fun.()
    end
  end

  @doc "Return current state of a named circuit."
  @spec status(circuit_name()) :: circuit_state()
  def status(name) do
    GenServer.call(__MODULE__, {:status, name})
  end

  @doc "Manually reset (close) a circuit breaker."
  @spec reset(circuit_name()) :: :ok
  def reset(name) do
    GenServer.call(__MODULE__, {:reset, name})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl true
  def handle_call({:status, name}, _from, state) do
    circuit = get_circuit(name)
    {:reply, circuit, state}
  end

  @impl true
  def handle_call({:reset, name}, _from, state) do
    new_circuit = initial_state(name)
    :ets.insert(:aurinko_circuits, {name, new_circuit})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_success, name}, _from, state) do
    circuit = get_circuit(name)

    new_circuit =
      case circuit.state do
        :half_open ->
          Logger.info("[Aurinko.CircuitBreaker] Circuit '#{name}' CLOSED after probe success")

          :telemetry.execute(
            [:aurinko_ex, :circuit_breaker, :closed],
            %{count: 1},
            %{circuit: name}
          )

          %{circuit | state: :closed, failure_count: 0, opened_at: nil, success_count: 0}

        _ ->
          %{circuit | failure_count: 0}
      end

    :ets.insert(:aurinko_circuits, {name, new_circuit})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_failure, name}, _from, state) do
    circuit = get_circuit(name)
    now = System.monotonic_time(:millisecond)
    threshold = configured_threshold()

    new_failure_count = circuit.failure_count + 1

    new_circuit =
      cond do
        circuit.state == :half_open ->
          # Probe failed — reopen
          Logger.warning(
            "[Aurinko.CircuitBreaker] Circuit '#{name}' REOPENED after probe failure"
          )

          :telemetry.execute(
            [:aurinko_ex, :circuit_breaker, :opened],
            %{count: 1},
            %{circuit: name, reason: :probe_failure}
          )

          %{
            circuit
            | state: :open,
              opened_at: now,
              failure_count: new_failure_count,
              last_failure_at: now
          }

        new_failure_count >= threshold ->
          Logger.warning(
            "[Aurinko.CircuitBreaker] Circuit '#{name}' OPENED after #{new_failure_count} failures"
          )

          :telemetry.execute(
            [:aurinko_ex, :circuit_breaker, :opened],
            %{count: 1},
            %{circuit: name, reason: :threshold_exceeded}
          )

          %{
            circuit
            | state: :open,
              opened_at: now,
              failure_count: new_failure_count,
              last_failure_at: now
          }

        true ->
          %{circuit | failure_count: new_failure_count, last_failure_at: now}
      end

    :ets.insert(:aurinko_circuits, {name, new_circuit})
    {:reply, :ok, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp check_state(name) do
    circuit = get_circuit(name)
    now = System.monotonic_time(:millisecond)
    timeout = configured_timeout()

    case circuit.state do
      :closed ->
        :allow

      :open ->
        if circuit.opened_at && now - circuit.opened_at >= timeout do
          # Transition to half-open
          new_circuit = %{circuit | state: :half_open}
          :ets.insert(:aurinko_circuits, {name, new_circuit})

          Logger.info("[Aurinko.CircuitBreaker] Circuit '#{name}' → HALF-OPEN (probing)")
          :allow
        else
          :reject
        end

      :half_open ->
        # Only one probe at a time — subsequent requests are rejected
        :reject
    end
  end

  defp execute(name, fun) do
    try do
      result = fun.()

      case result do
        {:error, %Aurinko.Error{type: type}}
        when type in [:server_error, :network_error, :timeout] ->
          GenServer.call(__MODULE__, {:record_failure, name})
          result

        {:error, :circuit_open} ->
          result

        _ ->
          GenServer.call(__MODULE__, {:record_success, name})
          result
      end
    rescue
      exception ->
        GenServer.call(__MODULE__, {:record_failure, name})
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        GenServer.call(__MODULE__, {:record_failure, name})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp get_circuit(name) do
    case :ets.lookup(:aurinko_circuits, name) do
      [{^name, circuit}] -> circuit
      [] -> initial_state(name)
    end
  end

  defp initial_state(name) do
    %{
      name: name,
      state: :closed,
      failure_count: 0,
      last_failure_at: nil,
      opened_at: nil,
      success_count: 0
    }
  end

  defp enabled?, do: Application.get_env(:aurinko_ex, :circuit_breaker_enabled, true)

  defp configured_threshold,
    do: Application.get_env(:aurinko_ex, :circuit_breaker_threshold, @default_threshold)

  defp configured_timeout,
    do: Application.get_env(:aurinko_ex, :circuit_breaker_timeout, @default_timeout)
end
