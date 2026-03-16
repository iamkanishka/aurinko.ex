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

  alias Aurinko.API.{Calendar, Contacts, Email}
  alias Aurinko.{Error, Paginator}

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
  """
  @spec sync_email(String.t(), sync_opts()) :: {:ok, sync_result()} | {:error, Error.t()}
  def sync_email(token, opts) do
    start_time = System.monotonic_time(:millisecond)
    on_updated = Keyword.get(opts, :on_updated, fn _ -> :ok end)
    on_deleted = Keyword.get(opts, :on_deleted, fn _ -> :ok end)
    save_tokens = Keyword.fetch!(opts, :save_tokens)

    Logger.info("[Aurinko.Sync] Starting email sync")

    case resolve_email_tokens(token, opts) do
      {:ok, {updated_token, deleted_token}} ->
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
            "[Aurinko.Sync] Email sync complete — #{updated_count} updated, " <>
              "#{deleted_count} deleted in #{duration}ms"
          )

          {:ok,
           Map.merge(new_tokens, %{
             updated: updated_count,
             deleted: deleted_count,
             duration_ms: duration
           })}
        end

      {:error, _} = err ->
        err
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
    on_updated = Keyword.get(opts, :on_updated, fn _ -> :ok end)
    on_deleted = Keyword.get(opts, :on_deleted, fn _ -> :ok end)
    save_tokens = Keyword.fetch!(opts, :save_tokens)

    Logger.info("[Aurinko.Sync] Starting calendar sync for #{calendar_id}")

    case resolve_calendar_tokens(token, calendar_id, opts) do
      {:ok, {updated_token, deleted_token}} ->
        drain_calendar_sync(
          token,
          calendar_id,
          updated_token,
          deleted_token,
          on_updated,
          on_deleted,
          save_tokens,
          start_time
        )

      {:error, _} = err ->
        err
    end
  end

  defp drain_calendar_sync(
         token,
         calendar_id,
         updated_token,
         deleted_token,
         on_updated,
         on_deleted,
         save_tokens,
         start_time
       ) do
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

  # <-- ADDED (this was the missing end)

  # ── Contacts sync ─────────────────────────────────────────────────────────────

  @doc """
  Run a full or incremental contacts sync.
  """
  @spec sync_contacts(String.t(), sync_opts()) :: {:ok, sync_result()} | {:error, Error.t()}
  def sync_contacts(token, opts) do
    start_time = System.monotonic_time(:millisecond)
    on_updated = Keyword.get(opts, :on_updated, fn _ -> :ok end)
    save_tokens = Keyword.fetch!(opts, :save_tokens)

    Logger.info("[Aurinko.Sync] Starting contacts sync")

    case resolve_contacts_tokens(token, opts) do
      {:ok, {updated_token, _deleted_token}} ->
        case drain_sync(token, updated_token, &Contacts.sync_updated(&1, &2), on_updated) do
          {:ok, {new_updated_token, updated_count}} ->
            new_tokens = %{sync_updated_token: new_updated_token, sync_deleted_token: nil}
            save_tokens.(new_tokens)

            duration = System.monotonic_time(:millisecond) - start_time
            emit_sync_complete(:contacts, updated_count, 0, duration)

            {:ok,
             Map.merge(new_tokens, %{updated: updated_count, deleted: 0, duration_ms: duration})}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  @spec resolve_email_tokens(String.t(), sync_opts()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, Error.t()}
  defp resolve_email_tokens(token, opts) do
    get_tokens = Keyword.get(opts, :get_tokens, fn -> nil end)
    days_within = Keyword.get(opts, :days_within, 30)

    case get_tokens.() do
      %{sync_updated_token: upd, sync_deleted_token: del} when is_binary(upd) ->
        {:ok, {upd, del}}

      _ ->
        start_email_sync(token, days_within)
    end
  end

  @spec start_email_sync(String.t(), pos_integer()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, Error.t()}
  defp start_email_sync(token, days_within) do
    case start_sync_with_retry(fn -> Email.start_sync(token, days_within: days_within) end) do
      {:ok, sync} -> {:ok, {sync.sync_updated_token, sync.sync_deleted_token}}
      {:error, _} = err -> err
    end
  end

  @spec resolve_calendar_tokens(String.t(), String.t(), sync_opts()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, Error.t()}
  defp resolve_calendar_tokens(token, calendar_id, opts) do
    get_tokens = Keyword.get(opts, :get_tokens, fn -> nil end)

    case get_tokens.() do
      %{sync_updated_token: upd, sync_deleted_token: del} when is_binary(upd) ->
        {:ok, {upd, del}}

      _ ->
        start_calendar_sync(token, calendar_id, opts)
    end
  end

  @spec start_calendar_sync(String.t(), String.t(), sync_opts()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, Error.t()}
  defp start_calendar_sync(token, calendar_id, opts) do
    time_min = Keyword.get(opts, :time_min, DateTime.add(DateTime.utc_now(), -365, :day))
    time_max = Keyword.get(opts, :time_max, DateTime.add(DateTime.utc_now(), 365, :day))

    case start_sync_with_retry(fn ->
           Calendar.start_sync(token, calendar_id, time_min: time_min, time_max: time_max)
         end) do
      {:ok, sync} -> {:ok, {sync.sync_updated_token, sync.sync_deleted_token}}
      {:error, _} = err -> err
    end
  end

  @spec resolve_contacts_tokens(String.t(), sync_opts()) ::
          {:ok, {String.t(), nil}} | {:error, Error.t()}
  defp resolve_contacts_tokens(token, opts) do
    get_tokens = Keyword.get(opts, :get_tokens, fn -> nil end)

    case get_tokens.() do
      %{sync_updated_token: upd} when is_binary(upd) ->
        {:ok, {upd, nil}}

      _ ->
        start_contacts_sync(token)
    end
  end

  @spec start_contacts_sync(String.t()) :: {:ok, {String.t(), nil}} | {:error, Error.t()}
  defp start_contacts_sync(token) do
    case start_sync_with_retry(fn -> Contacts.start_sync(token) end) do
      {:ok, sync} -> {:ok, {sync.sync_updated_token, nil}}
      {:error, _} = err -> err
    end
  end

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

  defp drain_sync(token, delta_token, fetch_fn, on_batch) do
    result =
      Paginator.sync_stream(token, delta_token, fetch_fn,
        on_delta: fn new_tok ->
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
      [:aurinko, :sync, :complete],
      %{updated: updated, deleted: deleted, duration_ms: duration_ms},
      %{resource: resource}
    )
  end
end
