defmodule Aurinko.API.Email do
  @moduledoc """
  Aurinko Email API — messages, drafts, sync, and tracking.

  Supports Gmail, Office 365, Outlook.com, MS Exchange, Zoho Mail, iCloud, and IMAP.

  ## Sync Model

  Aurinko uses a delta/token-based sync model. The typical workflow is:

  1. Call `start_sync/2` to provision the sync.
  2. Call `sync_updated/3` and `sync_deleted/3` with the returned tokens for initial full sync.
  3. On subsequent syncs, reuse the `next_delta_token` for incremental updates.

  ## Examples

      # List inbox messages
      {:ok, page} = Aurinko.Email.list_messages(token, limit: 25, q: "is:unread")

      # Start sync
      {:ok, sync} = Aurinko.Email.start_sync(token, days_within: 30)

      # Get updated messages
      {:ok, page} = Aurinko.Email.sync_updated(token, sync.sync_updated_token)
  """

  alias Aurinko.HTTP.Client
  alias Aurinko.Types.{Email, Pagination, SyncResult}
  alias Aurinko.Error

  # ── Messages ─────────────────────────────────────────────────────────────────

  @doc """
  List email messages. Optionally filter with query operators.

  ## Options

  - `:limit` — Number of messages to return (default: 20, max: 200)
  - `:page_token` — Token for pagination
  - `:q` — Search query string (e.g. `"from:user@example.com"`, `"is:unread"`)
  - `:body_type` — `"html"` or `"text"` (default: `"text"`)
  - `:load_body` — Whether to load message body (default: false)

  ## Examples

      {:ok, page} = Aurinko.Email.list_messages(token,
        limit: 10,
        q: "from:[email protected]",
        load_body: true
      )
  """
  @spec list_messages(String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def list_messages(token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:limit, :page_token, :q, :body_type, :load_body])
      |> Keyword.put_new(:limit, 20)
      |> camelize_params()

    with {:ok, body} <- Client.get(token, "/email/messages", params: params) do
      {:ok, Pagination.from_response(body)}
    end
  end

  @doc """
  Get a single email message by ID.

  ## Options

  - `:body_type` — `"html"` or `"text"` (default: `"text"`)
  """
  @spec get_message(String.t(), String.t(), keyword()) ::
          {:ok, Email.t()} | {:error, Error.t()}
  def get_message(token, id, opts \\ []) do
    params = opts |> Keyword.take([:body_type]) |> camelize_params()

    with {:ok, body} <- Client.get(token, "/email/messages/#{id}", params: params) do
      {:ok, Email.from_response(body)}
    end
  end

  @doc """
  Send a new email message.

  ## Parameters

  - `:to` — List of recipient addresses (required). e.g. `[%{address: "user@example.com", name: "User"}]`
  - `:subject` — Email subject
  - `:body` — Email body content
  - `:body_type` — `"html"` or `"text"`
  - `:cc` — CC recipients
  - `:bcc` — BCC recipients
  - `:reply_to_message_id` — ID of message being replied to
  - `:tracking` — Tracking options map (`:opens`, `:thread_replies`, `:context`)

  ## Examples

      {:ok, message} = Aurinko.Email.send_message(token, %{
        to: [%{address: "[email protected]"}],
        subject: "Hello",
        body: "<h1>Hello!</h1>",
        body_type: "html",
        tracking: %{opens: true, thread_replies: true}
      })
  """
  @spec send_message(String.t(), map()) ::
          {:ok, Email.t()} | {:error, Error.t()}
  def send_message(token, %{to: _} = params) do
    body = build_message_body(params)
    query = if params[:body_type], do: [bodyType: params[:body_type]], else: []

    with {:ok, resp} <- Client.post(token, "/email/messages", body, params: query) do
      {:ok, Email.from_response(resp)}
    end
  end

  def send_message(_token, _params),
    do: {:error, Error.invalid_params("`:to` is required when sending a message")}

  @doc """
  Mark a message as read or unread.
  """
  @spec update_message(String.t(), String.t(), map()) ::
          {:ok, Email.t()} | {:error, Error.t()}
  def update_message(token, id, params) do
    body = Map.take(params, [:is_read, :is_flagged]) |> camelize_map()

    with {:ok, resp} <- Client.patch(token, "/email/messages/#{id}", body) do
      {:ok, Email.from_response(resp)}
    end
  end

  # ── Drafts ───────────────────────────────────────────────────────────────────

  @doc """
  Create a new email draft.
  """
  @spec create_draft(String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_draft(token, params) do
    body = build_message_body(params)

    with {:ok, resp} <- Client.post(token, "/email/drafts", body) do
      {:ok, resp}
    end
  end

  @doc """
  Delete a draft by ID.
  """
  @spec delete_draft(String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def delete_draft(token, id) do
    with {:ok, _} <- Client.delete(token, "/email/drafts/#{id}") do
      :ok
    end
  end

  # ── Sync ─────────────────────────────────────────────────────────────────────

  @doc """
  Start or resume an email sync. Returns delta tokens when ready.

  ## Options

  - `:days_within` — Limit initial scan to emails received in the past N days
  - `:await_ready` — Block until sync is ready (default: false)

  ## Examples

      {:ok, %SyncResult{ready: true, sync_updated_token: token}} =
        Aurinko.Email.start_sync(access_token, days_within: 30)
  """
  @spec start_sync(String.t(), keyword()) ::
          {:ok, SyncResult.t()} | {:error, Error.t()}
  def start_sync(token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:days_within, :await_ready])
      |> camelize_params()

    with {:ok, body} <- Client.post(token, "/email/sync", nil, params: params) do
      {:ok, SyncResult.from_response(body)}
    end
  end

  @doc """
  Fetch updated (new or modified) emails since the last sync.

  Pass `delta_token` on the first call and then `next_delta_token`/`next_page_token`
  from each subsequent response.

  ## Options

  - `:body_type` — `"html"` or `"text"`
  - `:load_body` — Whether to load message bodies
  """
  @spec sync_updated(String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def sync_updated(token, delta_token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:body_type, :load_body, :page_token])
      |> Keyword.put(:delta_token, delta_token)
      |> camelize_params()

    with {:ok, body} <- Client.get(token, "/email/sync/updated", params: params) do
      {:ok, Pagination.from_response(body)}
    end
  end

  @doc """
  Fetch deleted email IDs since the last sync.
  """
  @spec sync_deleted(String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def sync_deleted(token, delta_token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:page_token])
      |> Keyword.put(:delta_token, delta_token)
      |> camelize_params()

    with {:ok, body} <- Client.get(token, "/email/sync/deleted", params: params) do
      {:ok, Pagination.from_response(body)}
    end
  end

  # ── Attachments ──────────────────────────────────────────────────────────────

  @doc """
  List attachments for a given message.
  """
  @spec list_attachments(String.t(), String.t()) ::
          {:ok, list(map())} | {:error, Error.t()}
  def list_attachments(token, message_id) do
    with {:ok, body} <- Client.get(token, "/email/messages/#{message_id}/attachments") do
      {:ok, body["records"] || []}
    end
  end

  @doc """
  Download a specific attachment.
  """
  @spec get_attachment(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def get_attachment(token, message_id, attachment_id) do
    Client.get(token, "/email/messages/#{message_id}/attachments/#{attachment_id}")
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp build_message_body(params) do
    %{}
    |> maybe_put(:subject, params[:subject])
    |> maybe_put(:body, params[:body])
    |> maybe_put(:to, format_addresses(params[:to]))
    |> maybe_put(:cc, format_addresses(params[:cc]))
    |> maybe_put(:bcc, format_addresses(params[:bcc]))
    |> maybe_put(:replyToMessageId, params[:reply_to_message_id])
    |> maybe_put(:tracking, format_tracking(params[:tracking]))
  end

  defp format_addresses(nil), do: nil

  defp format_addresses(addrs) when is_list(addrs) do
    Enum.map(addrs, fn
      %{address: addr} = a -> %{"address" => addr, "name" => a[:name]}
      addr when is_binary(addr) -> %{"address" => addr}
    end)
  end

  defp format_tracking(nil), do: nil

  defp format_tracking(%{} = t) do
    %{}
    |> maybe_put(:opens, t[:opens])
    |> maybe_put(:threadReplies, t[:thread_replies])
    |> maybe_put(:trackOpensAfterSendDelay, t[:track_opens_after_send_delay])
    |> maybe_put(:context, t[:context])
    |> maybe_put(:customDomainAlias, t[:custom_domain_alias])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp camelize_params(kw) do
    Enum.map(kw, fn {k, v} -> {camelize(k), v} end)
  end

  defp camelize_map(map) do
    Map.new(map, fn {k, v} -> {camelize(k), v} end)
  end

  defp camelize(key) when is_atom(key) do
    key |> Atom.to_string() |> camelize()
  end

  defp camelize(str) when is_binary(str) do
    [first | rest] = String.split(str, "_")
    first <> Enum.map_join(rest, "", &String.capitalize/1)
  end
end
