defmodule Aurinko.Sync.Orchestrator do
  @moduledoc """
  High-level sync orchestrator for email, calendar, and contacts.

  Manages the full lifecycle of Aurinko's delta-sync model:

  1. Start or resume a sync session
  2. Load all updated records (paging automatically)
  3. Load all deleted record IDs
  4. Persist the delta tokens for the next run
  5. Emit telemetry events per batch

  ## Usage

      # Full or incremental email sync
      {:ok, result} = Aurinko.Sync.Orchestrator.sync_email(token,
        days_within: 30,
        on_updated: fn records -> MyApp.Mailbox.upsert_many(records) end,
        on_deleted: fn ids -> MyApp.Mailbox.delete_many(ids) end,
        get_tokens: fn -> MyApp.Store.get_delta_tokens("email") end,
        save_tokens: fn tokens -> MyApp.Store.save_delta_tokens("email", tokens) end
      )

      # Calendar sync
      {:ok, result} = Aurinko.Sync.Orchestrator.sync_calendar(token, "primary",
        time_min: ~U[2024-01-01 00:00:00Z],
        time_max: ~U[2024-12-31 23:59:59Z],
        on_updated: fn records -> MyApp.Calendar.upsert_events(records) end,
        on_deleted: fn ids -> MyApp.Calendar.delete_events(ids) end,
        get_tokens: fn -> MyApp.Store.get_delta_tokens("calendar:primary") end,
        save_tokens: fn tokens -> MyApp.Store.save_delta_tokens("calendar:primary", tokens) end
      )
  """

  require Logger

  alias Aurinko.API.{Email, Calendar, Contacts}
  alias Aurinko.{Paginator, Error}

  @type sync_result :: %{
          updated: non_neg_integer(),
          deleted: non_neg_integer(),
          duration_ms: non_neg_integer(),
          sync_updated_token: String.t() | nil,
          sync_deleted_token: String.t() | nil
        }

  @type sync_opts :: [
          days_within: pos_integer(),
          on_updated: (list() -> any()),
          on_deleted: (list() -> any()),
          get_tokens: (-> map() | nil),
          save_tokens: (map() -> any()),
          batch_size: pos_integer()
        ]

  # ── Email sync ────────────────────────────────────────────────────────────────

  @doc """
  Run a full or incremental email sync.

  If `get_tokens` returns existing delta tokens, an incremental sync is performed.
  Otherwise, a new full sync is started.

  ## Required options

  - `:on_updated` — Called with each batch of updated message maps
  - `:on_deleted` — Called with each batch of deleted message IDs
  - `:get_tokens` — Returns `%{sync_updated_token: ..., sync_deleted_token: ...}` or `nil`
  - `:save_tokens` — Persists the new delta tokens after a successful sync
  """
  @spec sync_email(String.t(), sync_opts()) :: {:ok, sync_result()} | {:error, Error.t()}
  def sync_email(token, opts) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[Aurinko.Sync] Starting email sync")

    with {:ok, {updated_token, deleted_token}} <- resolve_email_tokens(token, opts) do
      on_updated = Keyword.get(opts, :on_updated, fn _ -> :ok end)
      on_deleted = Keyword.get(opts, :on_deleted, fn _ -> :ok end)
      save_tokens = Keyword.fetch!(opts, :save_tokens)

      Logger.debug("[Aurinko.Sync] Email sync tokens resolved — running delta")

      with {:ok, {new_updated_token, updated_count}} <-
             drain_sync(token, updated_token, &Email.sync_updated(&1, &2), on_updated),
           {:ok, {new_deleted_token, deleted_count}} <-
             drain_sync(token, deleted_token, &Email.sync_deleted(&1, &2), on_deleted) do
        new_tokens = %{
          sync_updated_token: new_updated_token,
          sync_deleted_token: new_deleted_token
        }

        save_tokens.(new_tokens)

        duration = System.monotonic_time(:millisecond) - start_time

        emit_sync_complete(:email, updated_count, deleted_count, duration)

        Logger.info(
          "[Aurinko.Sync] Email sync complete — #{updated_count} updated, #{deleted_count} deleted in #{duration}ms"
        )

        {:ok,
         Map.merge(new_tokens, %{
           updated: updated_count,
           deleted: deleted_count,
           duration_ms: duration
         })}
      end
    end
  end

  # ── Calendar sync ─────────────────────────────────────────────────────────────

  @doc """
  Run a full or incremental calendar sync for a given calendar.
  """
  @spec sync_calendar(String.t(), String.t(), sync_opts()) ::
          {:ok, sync_result()} | {:error, Error.t()}
  def sync_calendar(token, calendar_id, opts) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[Aurinko.Sync] Starting calendar sync for #{calendar_id}")

    with {:ok, {updated_token, deleted_token}} <-
           resolve_calendar_tokens(token, calendar_id, opts) do
      on_updated = Keyword.get(opts, :on_updated, fn _ -> :ok end)
      on_deleted = Keyword.get(opts, :on_deleted, fn _ -> :ok end)
      save_tokens = Keyword.fetch!(opts, :save_tokens)

      with {:ok, {new_updated_token, updated_count}} <-
             drain_sync(
               token,
               updated_token,
               fn t, dt -> Calendar.sync_updated(t, calendar_id, dt) end,
               on_updated
             ),
           {:ok, {new_deleted_token, deleted_count}} <-
             drain_sync(
               token,
               deleted_token,
               fn t, dt -> Calendar.sync_deleted(t, calendar_id, dt) end,
               on_deleted
             ) do
        new_tokens = %{
          sync_updated_token: new_updated_token,
          sync_deleted_token: new_deleted_token
        }

        save_tokens.(new_tokens)

        duration = System.monotonic_time(:millisecond) - start_time
        emit_sync_complete(:calendar, updated_count, deleted_count, duration)

        {:ok,
         Map.merge(new_tokens, %{
           updated: updated_count,
           deleted: deleted_count,
           duration_ms: duration
         })}
      end
    end
  end

  # ── Contacts sync ─────────────────────────────────────────────────────────────

  @doc """
  Run a full or incremental contacts sync.
  """
  @spec sync_contacts(String.t(), sync_opts()) :: {:ok, sync_result()} | {:error, Error.t()}
  def sync_contacts(token, opts) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[Aurinko.Sync] Starting contacts sync")

    with {:ok, {updated_token, _}} <- resolve_contacts_tokens(token, opts) do
      on_updated = Keyword.get(opts, :on_updated, fn _ -> :ok end)
      _on_deleted = Keyword.get(opts, :on_deleted, fn _ -> :ok end)
      save_tokens = Keyword.fetch!(opts, :save_tokens)

      with {:ok, {new_updated_token, updated_count}} <-
             drain_sync(token, updated_token, &Contacts.sync_updated(&1, &2), on_updated) do
        new_tokens = %{sync_updated_token: new_updated_token, sync_deleted_token: nil}
        save_tokens.(new_tokens)

        duration = System.monotonic_time(:millisecond) - start_time
        emit_sync_complete(:contacts, updated_count, 0, duration)

        {:ok, Map.merge(new_tokens, %{updated: updated_count, deleted: 0, duration_ms: duration})}
      end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp resolve_email_tokens(token, opts) do
    get_tokens = Keyword.get(opts, :get_tokens, fn -> nil end)
    days_within = Keyword.get(opts, :days_within, 30)

    case get_tokens.() do
      %{sync_updated_token: upd, sync_deleted_token: del} when is_binary(upd) ->
        {:ok, {upd, del}}

      _ ->
        # No saved tokens — start a fresh sync
        with {:ok, sync} <-
               start_sync_with_retry(fn -> Email.start_sync(token, days_within: days_within) end) do
          {:ok, {sync.sync_updated_token, sync.sync_deleted_token}}
        end
    end
  end

  defp resolve_calendar_tokens(token, calendar_id, opts) do
    get_tokens = Keyword.get(opts, :get_tokens, fn -> nil end)

    case get_tokens.() do
      %{sync_updated_token: upd, sync_deleted_token: del} when is_binary(upd) ->
        {:ok, {upd, del}}

      _ ->
        time_min = Keyword.get(opts, :time_min, DateTime.add(DateTime.utc_now(), -365, :day))
        time_max = Keyword.get(opts, :time_max, DateTime.add(DateTime.utc_now(), 365, :day))

        with {:ok, sync} <-
               start_sync_with_retry(fn ->
                 Calendar.start_sync(token, calendar_id, time_min: time_min, time_max: time_max)
               end) do
          {:ok, {sync.sync_updated_token, sync.sync_deleted_token}}
        end
    end
  end

  defp resolve_contacts_tokens(token, opts) do
    get_tokens = Keyword.get(opts, :get_tokens, fn -> nil end)

    case get_tokens.() do
      %{sync_updated_token: upd} when is_binary(upd) ->
        {:ok, {upd, nil}}

      _ ->
        with {:ok, sync} <- start_sync_with_retry(fn -> Contacts.start_sync(token) end) do
          {:ok, {sync.sync_updated_token, nil}}
        end
    end
  end

  # Poll until sync is ready (Aurinko may need a few seconds to initialise)
  defp start_sync_with_retry(start_fn, attempt \\ 0) do
    case start_fn.() do
      {:ok, %{ready: true} = sync} ->
        {:ok, sync}

      {:ok, %{ready: false}} when attempt < 5 ->
        delay = 1_000 * (attempt + 1)
        Logger.debug("[Aurinko.Sync] Sync not ready — retrying in #{delay}ms")
        Process.sleep(delay)
        start_sync_with_retry(start_fn, attempt + 1)

      {:ok, %{ready: false}} ->
        {:error,
         %Error{type: :server_error, message: "Sync failed to initialise after 5 attempts"}}

      {:error, _} = err ->
        err
    end
  end

  # Drain all pages for a single sync direction (updated or deleted)
  defp drain_sync(token, delta_token, fetch_fn, on_batch) do
    _final_token_ref = {:done, delta_token}

    result =
      Paginator.sync_stream(token, delta_token, fetch_fn,
        on_delta: fn new_tok ->
          # Store new delta token via process dict so we can return it
          Process.put(:aurinko_sync_new_delta, new_tok)
        end
      )
      |> Stream.chunk_every(200)
      |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, count} ->
        case on_batch.(batch) do
          {:error, _} = err -> {:halt, err}
          _ -> {:cont, {:ok, count + length(batch)}}
        end
      end)

    case result do
      {:ok, count} ->
        new_token = Process.get(:aurinko_sync_new_delta, delta_token)
        Process.delete(:aurinko_sync_new_delta)
        {:ok, {new_token, count}}

      {:error, _} = err ->
        err
    end
  end

  defp emit_sync_complete(resource, updated, deleted, duration_ms) do
    :telemetry.execute(
      [:aurinko_ex, :sync, :complete],
      %{updated: updated, deleted: deleted, duration_ms: duration_ms},
      %{resource: resource}
    )
  end
end
