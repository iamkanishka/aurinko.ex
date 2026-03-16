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
    config = Application.get_all_env(:aurinko)
    base_url = Keyword.get(config, :base_url, "https://api.aurinko.io/v1")
    timeout = Keyword.get(config, :timeout, 30_000)

    req =
      Req.new(
        base_url: base_url,
        receive_timeout: timeout,
        connect_options: [timeout: 5_000],
        retry: false,
        decode_body: true
      )

    {:ok, %{req: req}}
  end

  # ── Public API ────────────────────────────────────────────────────────────────

  def get(token, path, opts \\ []), do: request(token, :get, path, nil, opts)
  def post(token, path, body \\ nil, opts \\ []), do: request(token, :post, path, body, opts)
  def patch(token, path, body, opts \\ []), do: request(token, :patch, path, body, opts)
  def put(token, path, body, opts \\ []), do: request(token, :put, path, body, opts)
  def delete(token, path, opts \\ []), do: request(token, :delete, path, nil, opts)

  # ── Core pipeline ─────────────────────────────────────────────────────────────

  defp request(token, method, path, body, opts) do
    config = Application.get_all_env(:aurinko)
    retry_attempts = Keyword.get(config, :retry_attempts, 3)
    retry_delay = Keyword.get(config, :retry_delay, 500)
    params = Keyword.get(opts, :params, [])
    headers = Keyword.get(opts, :headers, [])
    bypass_cache = Keyword.get(opts, :bypass_cache, false)
    cache_ttl = Keyword.get(opts, :cache_ttl, nil)

    circuit_name = circuit_key(method, path)
    cache_key = Cache.build_key(token, path, params)

    retry_opts = %{max: retry_attempts, base_delay: retry_delay}
    cache_opts = %{key: cache_key, ttl: cache_ttl, bypass: bypass_cache}

    req_info = %{
      token: token,
      method: method,
      path: path,
      body: body,
      params: params,
      headers: headers
    }

    start_time = System.monotonic_time()
    emit(:start, %{system_time: System.system_time()}, %{method: method, path: path})

    result =
      case apply_rate_limit(token) do
        {:wait, delay_ms} ->
          Logger.debug("[Aurinko] Rate-limit wait #{delay_ms}ms — #{method} #{path}")
          Process.sleep(delay_ms)
          run_through_circuit(circuit_name, req_info, retry_opts, cache_opts)

        :ok ->
          maybe_cached =
            if method in @cacheable_methods && !bypass_cache,
              do: Cache.get(cache_key),
              else: nil

          case maybe_cached do
            {:ok, cached} ->
              {:ok, cached}

            nil ->
              run_through_circuit(circuit_name, req_info, retry_opts, cache_opts)
          end
      end

    emit(:stop, %{duration: System.monotonic_time() - start_time}, %{
      method: method,
      path: path,
      result: result_tag(result)
    })

    result
  end

  defp run_through_circuit(circuit_name, req_info, retry_opts, cache_opts) do
    %{method: method} = req_info

    result =
      CircuitBreaker.call(circuit_name, fn ->
        http_result = execute_http(req_info, retry_opts, 0)
        maybe_cache_response(http_result, method, cache_opts)
        http_result
      end)

    case result do
      {:error, :circuit_open} ->
        {:error, %Error{type: :server_error, message: "Circuit breaker open"}}

      other ->
        other
    end
  end

  defp maybe_cache_response({:ok, value}, method, cache_opts)
       when method in @cacheable_methods do
    ttl_opts = if cache_opts.ttl, do: [ttl: cache_opts.ttl], else: []
    Cache.put(cache_opts.key, value, ttl_opts)
  end

  defp maybe_cache_response(_, _, _), do: :ok

  # ── HTTP execution with retry ─────────────────────────────────────────────────

  defp execute_http(req_info, retry_opts, attempt) do
    %{token: token, method: method, path: path, body: body, params: params, headers: headers} =
      req_info

    req = GenServer.call(__MODULE__, :get_req)

    req_opts =
      [method: method, url: path, headers: build_headers(token, headers), params: params]
      |> maybe_put_body(body)

    case Req.request(req, req_opts) do
      {:ok, response} ->
        handle_response(response, req_info, retry_opts, attempt)

      {:error, %Req.TransportError{reason: :timeout}} ->
        handle_timeout(req_info, retry_opts, attempt)

      {:error, exception} ->
        {:error, Error.network_error(exception)}
    end
  end

  defp handle_response(%Req.Response{status: s, body: b}, _req_info, _retry_opts, _attempt)
       when s in 200..299 do
    {:ok, b}
  end

  defp handle_response(%Req.Response{status: 429, headers: h}, req_info, retry_opts, attempt) do
    %{max: max, base_delay: base_delay} = retry_opts

    if attempt < max do
      delay = parse_retry_after(h) || exponential_delay(base_delay, attempt)
      retry_and_continue(req_info, retry_opts, attempt, :rate_limited, delay)
    else
      {:error,
       %Error{
         type: :rate_limited,
         message: "Rate limit exceeded after #{max} retries",
         status: 429
       }}
    end
  end

  defp handle_response(%Req.Response{status: s}, req_info, retry_opts, attempt)
       when s in 500..599 do
    %{max: max, base_delay: base_delay} = retry_opts

    if attempt < max do
      delay = exponential_delay(base_delay, attempt)
      retry_and_continue(req_info, retry_opts, attempt, :server_error, delay)
    else
      {:error, %Error{type: :server_error, message: "Server error #{s}", status: s}}
    end
  end

  defp handle_response(
         %Req.Response{status: s, body: b, headers: h},
         _req_info,
         _retry_opts,
         _attempt
       ) do
    {:error, Error.from_response(s, b, get_header(h, "x-request-id"))}
  end

  defp handle_timeout(req_info, retry_opts, attempt) do
    %{max: max, base_delay: base_delay} = retry_opts

    if attempt < max do
      delay = exponential_delay(base_delay, attempt)
      retry_and_continue(req_info, retry_opts, attempt, :timeout, delay)
    else
      {:error, %Error{type: :timeout, message: "Request timed out after #{max + 1} attempts"}}
    end
  end

  defp retry_and_continue(req_info, retry_opts, attempt, reason, delay) do
    %{method: method, path: path} = req_info
    %{max: max} = retry_opts

    warn_retry(method, path, attempt + 1, max, reason, delay)

    Process.sleep(delay)

    execute_http(req_info, retry_opts, attempt + 1)
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
    vsn = Application.spec(:aurinko, :vsn) || "dev"

    [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "aurinko/#{vsn} Elixir/#{System.version()}"}
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
      val -> String.to_integer(val) * 1000
    end
  rescue
    _ -> nil
  end

  # FIX: removed the unreachable fallback `get_header(_headers, _name)` clause.
  # Req always returns response headers as %{binary() => [binary()]}, so the
  # map-pattern clause below is exhaustive. The old catch-all could never be
  # reached and Dialyzer correctly flagged it as a pattern_match_cov violation.
  defp get_header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp circuit_key(method, path) do
    normalized =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn seg ->
        if Regex.match?(~r/^[a-zA-Z0-9_\-]{20,}$/, seg), do: ":id", else: seg
      end)

    "#{method}:#{normalized}"
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, _}), do: :error

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:aurinko, :request, event], measurements, metadata)
  end

  defp warn_retry(method, path, attempt, max, reason, delay) do
    Logger.warning(
      "[Aurinko] #{reason} — retry #{attempt}/#{max} in #{delay}ms (#{method} #{path})"
    )

    :telemetry.execute([:aurinko, :request, :retry], %{count: attempt}, %{
      method: method,
      path: path,
      reason: reason
    })
  end
end
