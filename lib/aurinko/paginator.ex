defmodule Aurinko.Paginator do
  @moduledoc """
  Lazy stream-based pagination for all Aurinko list endpoints.

  Instead of manually tracking `next_page_token` and `next_delta_token`,
  wrap any list function in a stream and consume it lazily.

  ## Usage

      # Lazy stream — only fetches pages as consumed
      stream = Aurinko.Paginator.stream(token, &Aurinko.Email.list_messages/2,
        limit: 50,
        q: "is:unread"
      )

      # Take the first 100 messages across all pages
      messages = stream |> Stream.take(100) |> Enum.to_list()

      # Or collect all into memory
      all_messages = Enum.to_list(stream)

      # Stream calendar events
      events =
        Aurinko.Paginator.stream(token, fn t, opts ->
          Aurinko.Calendar.list_events(t, "primary", opts)
        end, time_min: ~U[2024-01-01 00:00:00Z], time_max: ~U[2024-12-31 23:59:59Z])
        |> Enum.to_list()

  ## Sync streaming

  For delta-sync streams, use `sync_stream/4`:

      # Streams all updated records (pages handled automatically)
      {:ok, sync} = Aurinko.Email.start_sync(token, days_within: 30)

      Aurinko.Paginator.sync_stream(token, sync.sync_updated_token, fn t, delta_or_page_token, is_page ->
        if is_page do
          Aurinko.Email.sync_updated(token, delta_or_page_token)
        else
          Aurinko.Email.sync_updated(token, delta_or_page_token)
        end
      end)
      |> Stream.each(&process_message/1)
      |> Stream.run()
  """

  alias Aurinko.Types.Pagination

  @type fetch_fn :: (String.t(), keyword() -> {:ok, Pagination.t()} | {:error, term()})

  @doc """
  Create a lazy `Stream` that automatically paginates through all pages.

  The stream yields individual records (not page structs). Pages are fetched
  on demand as the stream is consumed.

  ## Parameters

  - `token` — Aurinko access token
  - `fetch_fn` — A function `(token, opts) -> {:ok, %Pagination{}}`. Any list API function works.
  - `opts` — Options forwarded to `fetch_fn` on every call (e.g. `:limit`, `:q`)

  ## Options

  - `:on_error` — `:halt` (default) or `:skip` — what to do on an API error mid-stream
  """
  @spec stream(String.t(), fetch_fn(), keyword()) :: Enumerable.t()
  def stream(token, fetch_fn, opts \\ []) do
    on_error = Keyword.get(opts, :on_error, :halt)
    fetch_opts = Keyword.drop(opts, [:on_error])

    Stream.resource(
      fn -> {:start, nil} end,
      fn
        :done ->
          {:halt, :done}

        {:start, nil} ->
          fetch_page(token, fetch_fn, fetch_opts, nil, on_error)

        {:next_page, page_token} ->
          fetch_page(token, fetch_fn, fetch_opts, page_token, on_error)
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Create a lazy `Stream` over a sync-updated or sync-deleted endpoint.

  Handles `next_page_token` (more pages in this sync batch) and
  `next_delta_token` (batch complete — use this token next time).

  Returns individual records. The final delta token is NOT yielded as a record —
  use the `:on_delta` callback to capture it.

  ## Options

  - `:on_delta` — `(delta_token -> any)` — called when a new delta token is received
  """
  @spec sync_stream(
          String.t(),
          String.t(),
          (String.t(), String.t() -> {:ok, Pagination.t()} | {:error, term()}),
          keyword()
        ) :: Enumerable.t()
  def sync_stream(token, initial_token, fetch_fn, opts \\ []) do
    on_delta = Keyword.get(opts, :on_delta, fn _tok -> :ok end)

    Stream.resource(
      fn -> {:token, initial_token} end,
      fn
        :done ->
          {:halt, :done}

        {:token, token_value} ->
          case fetch_fn.(token, token_value) do
            {:ok,
             %Pagination{records: records, next_page_token: page_tok, next_delta_token: delta_tok}} ->
              next_state =
                cond do
                  not is_nil(page_tok) ->
                    {:token, page_tok}

                  not is_nil(delta_tok) ->
                    on_delta.(delta_tok)
                    :done

                  true ->
                    :done
                end

              {records, next_state}

            {:error, reason} ->
              {[{:error, reason}], :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Collect all pages synchronously and return a flat list of records.

  Convenience wrapper around `stream/3` for when you want all results.
  """
  @spec collect_all(String.t(), fetch_fn(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def collect_all(token, fetch_fn, opts \\ []) do
    stream(token, fetch_fn, Keyword.put(opts, :on_error, :halt))
    |> Enum.reduce_while({:ok, []}, fn
      {:error, err}, _acc -> {:halt, {:error, err}}
      record, {:ok, acc} -> {:cont, {:ok, [record | acc]}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp fetch_page(token, fetch_fn, opts, page_token, on_error) do
    fetch_opts =
      if page_token,
        do: Keyword.put(opts, :page_token, page_token),
        else: opts

    case fetch_fn.(token, fetch_opts) do
      {:ok, %Pagination{records: records, next_page_token: next_page, next_delta_token: _delta}} ->
        next_state = if next_page, do: {:next_page, next_page}, else: :done
        {records, next_state}

      {:ok, %{records: records, next_page_token: next_page}} ->
        next_state = if next_page, do: {:next_page, next_page}, else: :done
        {records, next_state}

      {:ok, records} when is_list(records) ->
        {records, :done}

      {:error, reason} ->
        case on_error do
          :halt -> {[{:error, reason}], :done}
          :skip -> {[], :done}
        end
    end
  end
end
