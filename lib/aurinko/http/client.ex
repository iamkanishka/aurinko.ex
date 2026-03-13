defmodule Aurinko.HTTP.Client do
  @moduledoc """
  Production HTTP client for the Aurinko API.

  Middleware stack applied on every request:

  1. Rate limiting   — Token-bucket per-account + global RPS (`Aurinko.RateLimiter`)
  2. Circuit breaker — Per-path circuit breaker prevents cascading failures (`Aurinko.CircuitBreaker`)
  3. Caching         — ETS TTL cache for safe GET responses (`Aurinko.Cache`)
  4. Retry           — Exponential backoff + jitter for 429 / 5xx
  5. Telemetry       — Structured events for every request/response/retry
  6. Structured errors — All failures surface as `{:error, %Aurinko.Error{}}`
  """

  use GenServer
  require Logger

  alias Aurinko.{Cache, CircuitBreaker, Error, RateLimiter}

  @type method :: :get | :post | :patch | :put | :delete
  @type result :: {:ok, map() | list() | binary()} | {:error, Error.t()}

  @cacheable_methods [:get]
  @max_jitter 200

  # ── Lifecycle ─────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_all_env(:aurinko_ex)
    base_url = Keyword.get(config, :base_url, "https://api.aurinko.io/v1")
    timeout = Keyword.get(config, :timeout, 30_000)
    pool_size = Keyword.get(config, :pool_size, 10)

    req =
      Req.new(
        base_url: base_url,
        receive_timeout: timeout,
        connect_options: [pool_size: pool_size, timeout: 5_000],
        retry: false,
        decode_body: true
      )

    {:ok, %{req: req}}
  end

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec get(String.t(), String.t(), keyword()) :: result()
  def get(token, path, opts \\ []), do: request(token, :get, path, nil, opts)

  @spec post(String.t(), String.t(), map() | nil, keyword()) :: result()
  def post(token, path, body \\ nil, opts \\ []), do: request(token, :post, path, body, opts)

  @spec patch(String.t(), String.t(), map(), keyword()) :: result()
  def patch(token, path, body, opts \\ []), do: request(token, :patch, path, body, opts)

  @spec put(String.t(), String.t(), map(), keyword()) :: result()
  def put(token, path, body, opts \\ []), do: request(token, :put, path, body, opts)

  @spec delete(String.t(), String.t(), keyword()) :: result()
  def delete(token, path, opts \\ []), do: request(token, :delete, path, nil, opts)

  # ── Core pipeline ─────────────────────────────────────────────────────────────

  defp request(token, method, path, body, opts) do
    config = Application.get_all_env(:aurinko_ex)
    retry_attempts = Keyword.get(config, :retry_attempts, 3)
    retry_delay = Keyword.get(config, :retry_delay, 500)
    params = Keyword.get(opts, :params, [])
    headers = Keyword.get(opts, :headers, [])
    bypass_cache = Keyword.get(opts, :bypass_cache, false)
    cache_ttl = Keyword.get(opts, :cache_ttl, nil)

    circuit_name = circuit_key(method, path)
    cache_key = Cache.build_key(token, path, params)

    start_time = System.monotonic_time()
    emit(:start, %{system_time: System.system_time()}, %{method: method, path: path})

    result =
      case apply_rate_limit(token) do
        {:wait, delay_ms} ->
          Logger.debug("[Aurinko] Rate-limit wait #{delay_ms}ms — #{method} #{path}")
          Process.sleep(delay_ms)

          run_through_circuit(
            circuit_name,
            token,
            method,
            path,
            body,
            params,
            headers,
            retry_attempts,
            retry_delay,
            cache_key,
            cache_ttl,
            bypass_cache
          )

        :ok ->
          maybe_cached =
            if method in @cacheable_methods && !bypass_cache, do: Cache.get(cache_key), else: nil

          case maybe_cached do
            {:ok, cached} ->
              emit(:stop, %{duration: System.monotonic_time() - start_time}, %{
                method: method,
                path: path,
                result: :ok,
                cached: true
              })

              {:ok, cached}

            nil ->
              run_through_circuit(
                circuit_name,
                token,
                method,
                path,
                body,
                params,
                headers,
                retry_attempts,
                retry_delay,
                cache_key,
                cache_ttl,
                bypass_cache
              )
          end
      end

    emit(:stop, %{duration: System.monotonic_time() - start_time}, %{
      method: method,
      path: path,
      result: result_tag(result),
      cached: false
    })

    result
  end

  defp run_through_circuit(
         circuit_name,
         token,
         method,
         path,
         body,
         params,
         headers,
         retry_attempts,
         retry_delay,
         cache_key,
         cache_ttl,
         _bypass_cache
       ) do
    CircuitBreaker.call(circuit_name, fn ->
      result =
        execute_http(token, method, path, body, params, headers, retry_attempts, retry_delay, 0)

      if match?({:ok, _}, result) && method in @cacheable_methods do
        {:ok, value} = result
        ttl_opts = if cache_ttl, do: [ttl: cache_ttl], else: []
        Cache.put(cache_key, value, ttl_opts)
      end

      result
    end)
    |> case do
      {:error, :circuit_open} ->
        {:error,
         %Error{type: :server_error, message: "Circuit breaker open — #{path} is unavailable"}}

      other ->
        other
    end
  end

  # ── HTTP execution with retry ─────────────────────────────────────────────────

  defp execute_http(token, method, path, body, params, headers, max, base_delay, attempt) do
    req = GenServer.call(__MODULE__, :get_req)

    req_opts =
      [method: method, url: path, headers: build_headers(token, headers), params: params]
      |> maybe_put_body(body)

    case Req.request(req, req_opts) do
      {:ok, %Req.Response{status: s, body: b}} when s in 200..299 ->
        {:ok, b}

      {:ok, %Req.Response{status: 429, headers: h}} when attempt < max ->
        delay = parse_retry_after(h) || exponential_delay(base_delay, attempt)
        warn_retry(method, path, attempt + 1, max, :rate_limited, delay)
        Process.sleep(delay)
        execute_http(token, method, path, body, params, headers, max, base_delay, attempt + 1)

      {:ok, %Req.Response{status: 429}} ->
        {:error,
         %Error{
           type: :rate_limited,
           message: "Rate limit exceeded after #{max} retries",
           status: 429
         }}

      {:ok, %Req.Response{status: s}} when s in 500..599 and attempt < max ->
        delay = exponential_delay(base_delay, attempt)
        warn_retry(method, path, attempt + 1, max, :server_error, delay)
        Process.sleep(delay)
        execute_http(token, method, path, body, params, headers, max, base_delay, attempt + 1)

      {:ok, %Req.Response{status: s, body: b, headers: h}} ->
        {:error, Error.from_response(s, b, get_header(h, "x-request-id"))}

      {:error, %Req.TransportError{reason: :timeout}} when attempt < max ->
        delay = exponential_delay(base_delay, attempt)
        warn_retry(method, path, attempt + 1, max, :timeout, delay)
        Process.sleep(delay)
        execute_http(token, method, path, body, params, headers, max, base_delay, attempt + 1)

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, %Error{type: :timeout, message: "Request timed out after #{max + 1} attempts"}}

      {:error, exception} ->
        {:error, Error.network_error(exception)}
    end
  end

  @impl true
  def handle_call(:get_req, _from, %{req: req} = state), do: {:reply, req, state}

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp apply_rate_limit(token) do
    case RateLimiter.check_rate(token) do
      :ok -> :ok
      {:wait, ms} -> {:wait, ms}
    end
  end

  defp build_headers(token, extra) do
    vsn = Application.spec(:aurinko_ex, :vsn) || "dev"

    [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "aurinko_ex/#{vsn} Elixir/#{System.version()}"}
      | extra
    ]
  end

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :json, body)

  defp exponential_delay(base, attempt) do
    jitter = :rand.uniform(@max_jitter)
    trunc(base * :math.pow(2, attempt)) + jitter
  end

  defp parse_retry_after(headers) do
    case get_header(headers, "retry-after") do
      nil -> nil
      val -> String.to_integer(val) * 1_000
    end
  rescue
    _ -> nil
  end

  defp get_header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp get_header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp circuit_key(method, path) do
    normalized =
      path
      |> String.split("/")
      |> Enum.map(fn seg ->
        if Regex.match?(~r/^[a-zA-Z0-9_\-]{20,}$/, seg), do: ":id", else: seg
      end)
      |> Enum.join("/")

    "#{method}:#{normalized}"
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, _}), do: :error

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:aurinko_ex, :request, event], measurements, metadata)
  end

  defp warn_retry(method, path, attempt, max, reason, delay) do
    Logger.warning(
      "[Aurinko] #{reason} — retry #{attempt}/#{max} in #{delay}ms (#{method} #{path})"
    )

    :telemetry.execute([:aurinko_ex, :request, :retry], %{count: attempt}, %{
      method: method,
      path: path,
      reason: reason
    })
  end
end
