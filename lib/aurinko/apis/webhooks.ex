defmodule Aurinko.API.Webhooks do
  @moduledoc """
  Aurinko Webhooks API — subscribe to push notifications for data changes.

  Aurinko automatically manages webhook subscriptions and renewals.
  Your endpoint will receive push events when email, calendar, contacts, or tasks change.

  ## Example

      {:ok, sub} = Aurinko.Webhooks.create_subscription(token, %{
        resource: "email",
        notification_url: "https://yourapp.com/webhooks/aurinko",
        client_id: "optional-correlation-id"
      })
  """

  alias Aurinko.HTTP.Client
  alias Aurinko.Error

  @doc "List active webhook subscriptions."
  @spec list_subscriptions(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, Error.t()}
  def list_subscriptions(token, opts \\ []) do
    params = opts |> Keyword.take([:limit, :page_token]) |> camelize_params()

    with {:ok, body} <- Client.get(token, "/subscriptions", params: params) do
      {:ok, body["records"] || []}
    end
  end

  @doc """
  Create a webhook subscription.

  ## Parameters

  - `:resource` — Resource to subscribe to: `"email"`, `"calendar"`, `"contacts"`, `"tasks"` (required)
  - `:notification_url` — Your HTTPS endpoint to receive events (required)
  - `:client_id` — Optional client correlation string
  - `:expiration` — Optional expiration datetime
  """
  @spec create_subscription(String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_subscription(token, %{resource: _, notification_url: _} = params) do
    body =
      %{}
      |> maybe_put(:resource, params[:resource])
      |> maybe_put(:notificationUrl, params[:notification_url])
      |> maybe_put(:clientId, params[:client_id])
      |> maybe_put(:expiration, params[:expiration])

    Client.post(token, "/subscriptions", body)
  end

  def create_subscription(_token, _),
    do: {:error, Error.invalid_params("`:resource` and `:notification_url` are required")}

  @doc "Delete a webhook subscription by ID."
  @spec delete_subscription(String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def delete_subscription(token, id) do
    with {:ok, _} <- Client.delete(token, "/subscriptions/#{id}") do
      :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp camelize_params(kw), do: Enum.map(kw, fn {k, v} -> {camelize(k), v} end)
  defp camelize(key) when is_atom(key), do: key |> Atom.to_string() |> camelize()

  defp camelize(str) when is_binary(str) do
    [first | rest] = String.split(str, "_")
    first <> Enum.map_join(rest, "", &String.capitalize/1)
  end
end
