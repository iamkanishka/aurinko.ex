defmodule Aurinko.Auth do
  @moduledoc """
  OAuth authentication helpers for Aurinko.

  Aurinko supports three OAuth flows:

  1. **Account Flow** — User-delegated authorization producing an account + access token.
  2. **Service Account Flow** — Admin/Org-level authorization.
  3. **User Session Flow** — Produces an Aurinko User, primary account, and session token.

  ## Account Flow Example

      # Step 1: Redirect user to authorization URL
      url = Aurinko.Auth.authorize_url(
        service_type: "Google",
        scopes: ["Mail.Read", "Mail.Send", "Calendars.ReadWrite"],
        return_url: "https://yourapp.com/auth/callback",
        response_type: "code"
      )

      # Step 2: Exchange the code for a token
      {:ok, token_info} = Aurinko.Auth.exchange_code(code)

      # Use token_info.token for subsequent API calls
  """

  alias Aurinko.{Config, Error}

  @type token_info :: %{
          token: String.t(),
          account_id: integer(),
          service_type: String.t(),
          email: String.t() | nil
        }

  @supported_services ~w(Google Office365 Outlook EWS Zoho iCloud IMAP)

  @doc """
  Builds the Aurinko OAuth authorization URL.

  ## Options

  - `:service_type` — Provider to authorize (e.g. `"Google"`, `"Office365"`). Required.
  - `:scopes` — List of permission scopes. Defaults to `["Mail.Read"]`.
  - `:return_url` — Callback URL after authorization. Required.
  - `:response_type` — `"code"` (default) or `"token"`.
  - `:login_hint` — Pre-fill the user's email address.
  - `:state` — Optional opaque state value for CSRF protection.

  ## Examples

      iex> Aurinko.Auth.authorize_url(
      ...>   service_type: "Google",
      ...>   scopes: ["Mail.Read", "Calendars.ReadWrite"],
      ...>   return_url: "https://myapp.com/callback"
      ...> )
      "https://api.aurinko.io/v1/auth/authorize?..."
  """
  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts \\ []) do
    config = Config.load!()

    service_type = Keyword.fetch!(opts, :service_type)
    return_url = Keyword.fetch!(opts, :return_url)
    scopes = Keyword.get(opts, :scopes, ["Mail.Read"])
    response_type = Keyword.get(opts, :response_type, "code")
    state = Keyword.get(opts, :state)
    login_hint = Keyword.get(opts, :login_hint)

    unless service_type in @supported_services do
      raise ArgumentError,
            "Unsupported service_type: #{service_type}. Must be one of: #{Enum.join(@supported_services, ", ")}"
    end

    params =
      %{
        clientId: config.client_id,
        serviceType: service_type,
        scopes: Enum.join(scopes, " "),
        returnUrl: return_url,
        responseType: response_type
      }
      |> maybe_put(:state, state)
      |> maybe_put(:loginHint, login_hint)

    "#{config.base_url}/auth/authorize?" <> URI.encode_query(params)
  end

  @doc """
  Exchanges an authorization code for an Aurinko account access token.

  ## Examples

      {:ok, %{token: token, account_id: id}} = Aurinko.Auth.exchange_code("auth_code_here")
  """
  @spec exchange_code(String.t(), keyword()) ::
          {:ok, token_info()} | {:error, Error.t()}
  def exchange_code(code, _opts \\ []) when is_binary(code) do
    config = Config.load!()

    url = "#{config.base_url}/auth/token"

    body = %{
      code: code,
      clientId: config.client_id,
      clientSecret: config.client_secret
    }

    case Req.post(url, json: body, receive_timeout: config.timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_token_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, Error.network_error(exception)}
    end
  end

  @doc """
  Refreshes an expired Aurinko access token.
  """
  @spec refresh_token(String.t(), keyword()) ::
          {:ok, token_info()} | {:error, Error.t()}
  def refresh_token(refresh_token, _opts \\ []) when is_binary(refresh_token) do
    config = Config.load!()

    url = "#{config.base_url}/auth/token/refresh"

    body = %{
      refreshToken: refresh_token,
      clientId: config.client_id,
      clientSecret: config.client_secret
    }

    case Req.post(url, json: body, receive_timeout: config.timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_token_response(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response(status, body)}

      {:error, exception} ->
        {:error, Error.network_error(exception)}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp parse_token_response(body) do
    %{
      token: body["token"] || body["accessToken"],
      account_id: body["accountId"],
      service_type: body["serviceType"],
      email: body["email"]
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
