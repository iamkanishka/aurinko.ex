defmodule Aurinko.Error do
  @moduledoc """
  Structured error types returned by Aurinko API calls.

  All public functions return `{:ok, result}` or `{:error, Aurinko.Error.t()}`.
  """

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          status: integer() | nil,
          body: map() | String.t() | nil,
          request_id: String.t() | nil
        }

  @type error_type ::
          :auth_error
          | :not_found
          | :rate_limited
          | :server_error
          | :network_error
          | :timeout
          | :invalid_params
          | :config_error
          | :unknown

  defexception [:type, :message, :status, :body, :request_id]

  @impl true
  def message(%__MODULE__{type: type, message: msg, status: nil}),
    do: "[#{type}] #{msg}"

  def message(%__MODULE__{type: type, message: msg, status: status}),
    do: "[#{type}] HTTP #{status}: #{msg}"

  @doc """
  Build an `Aurinko.Error` from an HTTP response.
  """
  @spec from_response(integer(), map() | String.t(), String.t() | nil) :: t()
  def from_response(status, body, request_id \\ nil) do
    %__MODULE__{
      type: type_from_status(status),
      message: message_from_body(body),
      status: status,
      body: body,
      request_id: request_id
    }
  end

  @doc """
  Build a network/transport-level error.
  """
  @spec network_error(Exception.t() | String.t()) :: t()
  def network_error(%{message: msg}),
    do: %__MODULE__{type: :network_error, message: msg, status: nil, body: nil, request_id: nil}

  def network_error(msg) when is_binary(msg),
    do: %__MODULE__{type: :network_error, message: msg, status: nil, body: nil, request_id: nil}

  @doc """
  Build a parameter validation error.
  """
  @spec invalid_params(String.t()) :: t()
  def invalid_params(msg),
    do: %__MODULE__{type: :invalid_params, message: msg, status: nil, body: nil, request_id: nil}

  # Private helpers

  defp type_from_status(401), do: :auth_error
  defp type_from_status(403), do: :auth_error
  defp type_from_status(404), do: :not_found
  defp type_from_status(429), do: :rate_limited
  defp type_from_status(s) when s in 400..499, do: :invalid_params
  defp type_from_status(s) when s in 500..599, do: :server_error
  defp type_from_status(_), do: :unknown

  defp message_from_body(%{"message" => msg}), do: msg
  defp message_from_body(%{"error" => %{"message" => msg}}), do: msg
  defp message_from_body(%{"error" => msg}) when is_binary(msg), do: msg
  defp message_from_body(body) when is_binary(body) and byte_size(body) > 0, do: body
  defp message_from_body(_), do: "An unexpected error occurred"
end

defmodule Aurinko.ConfigError do
  @moduledoc "Raised when Aurinko configuration is invalid or missing."
  defexception [:message]
end
