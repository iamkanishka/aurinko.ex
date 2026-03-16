defmodule Aurinko.Webhook.Verifier do
  @moduledoc """
  HMAC-SHA256 signature verification for Aurinko webhook payloads.

  Aurinko signs outgoing webhook payloads with your client secret so you can
  verify they're genuine. Always verify signatures in production.

  ## Usage

  In a Phoenix controller or Plug endpoint:

      defmodule MyAppWeb.WebhookController do
        use MyAppWeb, :controller

        def receive(conn, _params) do
          signature = get_req_header(conn, "x-aurinko-signature") |> List.first()
          {:ok, raw_body} = get_raw_body(conn)

          case Aurinko.Webhook.Verifier.verify(raw_body, signature) do
            :ok ->
              payload = Jason.decode!(raw_body)
              MyApp.Webhooks.process(payload)
              send_resp(conn, 200, "ok")

            {:error, :invalid_signature} ->
              send_resp(conn, 401, "invalid signature")
          end
        end
      end

  ## Configuration

      config :aurinko,
        webhook_secret: System.get_env("AURINKO_WEBHOOK_SECRET")

  Or pass the secret explicitly:

      Aurinko.Webhook.Verifier.verify(body, signature, secret: "my_secret")
  """

  @doc """
  Verify an Aurinko webhook signature.

  Returns `:ok` on success, `{:error, :invalid_signature}` on failure.

  Timing-safe comparison is used to prevent timing attacks.
  """
  @spec verify(binary(), String.t() | nil, keyword()) :: :ok | {:error, :invalid_signature}
  def verify(body, signature, opts \\ [])

  def verify(_body, nil, _opts), do: {:error, :invalid_signature}
  def verify(_body, "", _opts), do: {:error, :invalid_signature}

  def verify(body, signature, opts) when is_binary(body) and is_binary(signature) do
    secret = Keyword.get(opts, :secret) || Application.get_env(:aurinko, :webhook_secret)

    if is_nil(secret) do
      {:error, :invalid_signature}
    else
      expected =
        :crypto.mac(:hmac, :sha256, secret, body)
        |> Base.encode16(case: :lower)

      # Strip optional "sha256=" prefix from Aurinko signature header
      received =
        signature
        |> String.replace_leading("sha256=", "")
        |> String.downcase()

      if secure_compare(expected, received) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  @doc """
  Compute the expected HMAC-SHA256 signature for a payload.

  Useful for testing your webhook endpoint.
  """
  @spec sign(binary(), String.t()) :: String.t()
  def sign(body, secret) when is_binary(body) and is_binary(secret) do
    "sha256=" <>
      (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  # Constant-time binary comparison to prevent timing attacks.
  # Compares digests of both values so length differences don't leak information.
  @spec secure_compare(binary(), binary()) :: boolean()
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b)
  end
end

defmodule Aurinko.Webhook.Handler do
  @moduledoc """
  Behaviour for implementing Aurinko webhook event handlers.

  ## Usage

      defmodule MyApp.AurinkoHandler do
        @behaviour Aurinko.Webhook.Handler

        @impl true
        def handle_event("email.new", payload, _meta) do
          MyApp.Mailbox.process_new_email(payload)
          :ok
        end

        def handle_event("calendar.event.updated", payload, _meta) do
          MyApp.Calendar.sync_event(payload)
          :ok
        end

        def handle_event(_event, _payload, _meta), do: :ok
      end

  Then in your router/controller, after verifying the signature:

      Aurinko.Webhook.Handler.dispatch(MyApp.AurinkoHandler, raw_body)
  """

  @type event_type :: String.t()
  @type payload :: map()
  @type meta :: %{raw_body: binary(), verified: boolean()}
  @type result :: :ok | {:error, term()}

  alias Aurinko.Webhook.Verifier

  @doc "Handle a parsed Aurinko webhook event."
  @callback handle_event(event_type(), payload(), meta()) :: result()

  @doc """
  Parse, verify, and dispatch a raw webhook body to a handler module.

  Returns `{:error, :invalid_signature}` if signature verification fails.
  """
  @spec dispatch(module(), binary(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def dispatch(handler, raw_body, signature \\ nil, opts \\ []) do
    with :ok <- maybe_verify(raw_body, signature, opts),
         {:ok, payload} <- Jason.decode(raw_body) do
      event_type = payload["eventType"] || payload["event"] || "unknown"
      meta = %{raw_body: raw_body, verified: not is_nil(signature)}

      try do
        handler.handle_event(event_type, payload, meta)
      rescue
        exception ->
          {:error, exception}
      end
    end
  end

  defp maybe_verify(_body, nil, _opts), do: :ok

  defp maybe_verify(body, signature, opts) do
    Verifier.verify(body, signature, opts)
  end
end
