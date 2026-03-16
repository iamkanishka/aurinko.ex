defmodule Aurinko.API.Contacts do
  @moduledoc """
  Aurinko Contacts API — read and manage address book contacts.

  Supports Google, Office 365, Outlook, and Exchange.
  """

  alias Aurinko.Error
  alias Aurinko.HTTP.Client
  alias Aurinko.Types.{Contact, Pagination, SyncResult}

  @doc """
  List contacts.

  ## Options

  - `:limit` — Number of results (default: 20)
  - `:page_token` — Pagination token
  - `:q` — Search query
  """
  @spec list_contacts(String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def list_contacts(token, opts \\ []) do
    params = opts |> Keyword.take([:limit, :page_token, :q]) |> camelize_params()

    case Client.get(token, "/contacts", params: params) do
      {:ok, body} ->
        {:ok, Pagination.from_response(body)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Get a contact by ID."
  @spec get_contact(String.t(), String.t()) ::
          {:ok, Contact.t()} | {:error, Error.t()}
  def get_contact(token, id) do
    case Client.get(token, "/contacts/#{id}") do
      {:ok, body} ->
        {:ok, Contact.from_response(body)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create a new contact.

  ## Parameters

  - `:given_name`, `:surname`, `:display_name`
  - `:email_addresses` — list of `%{address: "...", name: "..."}`
  - `:phone_numbers` — list of `%{number: "...", type: "..."}`
  - `:company`, `:job_title`
  """
  @spec create_contact(String.t(), map()) ::
          {:ok, Contact.t()} | {:error, Error.t()}
  def create_contact(token, params) do
    body = build_contact_body(params)

    case Client.post(token, "/contacts", body) do
      {:ok, resp} ->
        {:ok, Contact.from_response(resp)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Update an existing contact."
  @spec update_contact(String.t(), String.t(), map()) ::
          {:ok, Contact.t()} | {:error, Error.t()}
  def update_contact(token, id, params) do
    body = build_contact_body(params)

    case Client.patch(token, "/contacts/#{id}", body) do
      {:ok, resp} ->
        {:ok, Contact.from_response(resp)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Delete a contact by ID."
  @spec delete_contact(String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def delete_contact(token, id) do
    case Client.delete(token, "/contacts/#{id}") do
      {:ok, _} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Start incremental sync for contacts."
  @spec start_sync(String.t(), keyword()) ::
          {:ok, SyncResult.t()} | {:error, Error.t()}
  def start_sync(token, opts \\ []) do
    params = opts |> Keyword.take([:await_ready]) |> camelize_params()

    case Client.post(token, "/contacts/sync", nil, params: params) do
      {:ok, body} ->
        {:ok, SyncResult.from_response(body)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Fetch updated contacts since last sync."
  @spec sync_updated(String.t(), String.t(), keyword()) ::
          {:ok, Pagination.t()} | {:error, Error.t()}
  def sync_updated(token, delta_token, opts \\ []) do
    params =
      opts
      |> Keyword.take([:page_token])
      |> Keyword.put(:delta_token, delta_token)
      |> camelize_params()

    case Client.get(token, "/contacts/sync/updated", params: params) do
      {:ok, body} ->
        {:ok, Pagination.from_response(body)}

      {:error, _} = err ->
        err
    end
  end

  defp build_contact_body(params) do
    %{}
    |> maybe_put(:givenName, params[:given_name])
    |> maybe_put(:surname, params[:surname])
    |> maybe_put(:displayName, params[:display_name])
    |> maybe_put(:emailAddresses, params[:email_addresses])
    |> maybe_put(:phones, params[:phone_numbers])
    |> maybe_put(:companyName, params[:company])
    |> maybe_put(:jobTitle, params[:job_title])
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
