defmodule Aurinko.Telemetry do
  @moduledoc """
  Telemetry instrumentation for Aurinko.

  ## Events emitted

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:aurinko, :request, :start]` | `system_time` | `method, path` |
  | `[:aurinko, :request, :stop]` | `duration` | `method, path, result, cached` |
  | `[:aurinko, :request, :retry]` | `count` | `method, path, reason` |
  | `[:aurinko, :circuit_breaker, :opened]` | `count` | `circuit, reason` |
  | `[:aurinko, :circuit_breaker, :closed]` | `count` | `circuit` |
  | `[:aurinko, :circuit_breaker, :rejected]` | `count` | `circuit` |
  | `[:aurinko, :sync, :complete]` | `updated, deleted, duration_ms` | `resource` |

  ## Attach default structured logger

      Aurinko.Telemetry.attach_default_logger(:info)

  ## TelemetryMetrics definitions for reporters

      def metrics do
        Aurinko.Telemetry.metrics()
      end
  """

  use GenServer
  require Logger

  alias Telemetry.Metrics

  @all_events [
    [:aurinko, :request, :start],
    [:aurinko, :request, :stop],
    [:aurinko, :request, :retry],
    [:aurinko, :circuit_breaker, :opened],
    [:aurinko, :circuit_breaker, :closed],
    [:aurinko, :circuit_breaker, :rejected],
    [:aurinko, :sync, :complete]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :attach_default_logger, false) do
      attach_default_logger()
    end

    {:ok, %{}}
  end

  @doc "All telemetry event names emitted by Aurinko."
  @spec events() :: list(list(atom()))
  def events, do: @all_events

  @doc """
  `Telemetry.Metrics` definitions for reporters (Prometheus, StatsD, etc.).

  Add to your Phoenix `Telemetry` module:

      def metrics do
        [...your_metrics..., Aurinko.Telemetry.metrics()]
        |> List.flatten()
      end
  """
  @spec metrics() :: list(Metrics.t())
  def metrics do
    [
      Metrics.distribution("aurinko.request.stop.duration",
        unit: {:native, :millisecond},
        tags: [:method, :result],
        description: "Aurinko API request duration in ms",
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]]
      ),
      Metrics.counter("aurinko.request.stop.count",
        tags: [:method, :result, :cached],
        description: "Total Aurinko API requests"
      ),
      Metrics.counter("aurinko.request.retry.count",
        tags: [:method, :reason],
        description: "Aurinko API request retries"
      ),
      Metrics.counter("aurinko.circuit_breaker.opened.count",
        tags: [:circuit, :reason],
        description: "Circuit breaker open events"
      ),
      Metrics.counter("aurinko.circuit_breaker.rejected.count",
        tags: [:circuit],
        description: "Requests rejected by open circuit"
      ),
      Metrics.counter("aurinko.circuit_breaker.closed.count",
        tags: [:circuit],
        description: "Circuit breaker close events"
      ),
      Metrics.sum("aurinko.sync.complete.updated",
        tags: [:resource],
        description: "Total records updated by sync"
      ),
      Metrics.sum("aurinko.sync.complete.deleted",
        tags: [:resource],
        description: "Total records deleted by sync"
      ),
      Metrics.distribution("aurinko.sync.complete.duration_ms",
        tags: [:resource],
        description: "Sync duration in ms"
      )
    ]
  end

  @doc "Attach a structured logger for all Aurinko telemetry events."
  @spec attach_default_logger(Logger.level()) :: :ok | {:error, :already_exists}
  def attach_default_logger(level \\ :info) do
    :telemetry.attach_many(
      "aurinko-ex-default-logger",
      @all_events,
      &__MODULE__.log_event/4,
      %{level: level}
    )
  end

  @doc "Detach the default logger."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger do
    :telemetry.detach("aurinko-ex-default-logger")
  end

  @doc false
  def log_event([:aurinko, :request, :start], _m, %{method: method, path: path}, %{level: l}) do
    Logger.log(l, "[Aurinko] → #{String.upcase(to_string(method))} #{path}")
  end

  def log_event([:aurinko, :request, :stop], %{duration: d}, meta, %{level: l}) do
    ms = System.convert_time_unit(d, :native, :millisecond)
    cached_tag = if meta[:cached], do: " (cached)", else: ""

    Logger.log(
      l,
      "[Aurinko] ← #{meta[:result]} #{ms}ms#{cached_tag} #{meta[:method]} #{meta[:path]}"
    )
  end

  def log_event([:aurinko, :request, :retry], %{count: n}, %{reason: r, method: m, path: p}, _) do
    Logger.warning("[Aurinko] Retry ##{n} (#{r}): #{m} #{p}")
  end

  def log_event([:aurinko, :circuit_breaker, :opened], _, %{circuit: c, reason: r}, _) do
    Logger.error("[Aurinko] 🔴 Circuit OPENED: #{c} (#{r})")
  end

  def log_event([:aurinko, :circuit_breaker, :closed], _, %{circuit: c}, %{level: l}) do
    Logger.log(l, "[Aurinko] 🟢 Circuit CLOSED: #{c}")
  end

  def log_event([:aurinko, :circuit_breaker, :rejected], _, %{circuit: c}, _) do
    Logger.warning("[Aurinko] ⚫ Rejected (circuit open): #{c}")
  end

  def log_event(
        [:aurinko, :sync, :complete],
        %{updated: u, deleted: d, duration_ms: ms},
        %{resource: r},
        %{level: l}
      ) do
    Logger.log(l, "[Aurinko] ✓ Sync [#{r}] — #{u} updated, #{d} deleted in #{ms}ms")
  end

  def log_event(_event, _measurements, _metadata, _config), do: :ok
end
