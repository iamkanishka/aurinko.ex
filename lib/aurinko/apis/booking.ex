defmodule Aurinko.API.Booking do
  @moduledoc """
  Aurinko Booking API — scheduling, availability, and appointment booking.

  Supports listing booking profiles and fetching available time slots for meetings.
  """

  alias Aurinko.HTTP.Client
  alias Aurinko.Error

  @doc "List booking profiles."
  @spec list_booking_profiles(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, Error.t()}
  def list_booking_profiles(token, opts \\ []) do
    params = opts |> Keyword.take([:limit, :page_token]) |> camelize_params()

    with {:ok, body} <- Client.get(token, "/booking/profiles", params: params) do
      {:ok, body["records"] || []}
    end
  end

  @doc """
  Get availability slots for a booking profile.

  ## Parameters

  - `:time_min` — Start of availability window (DateTime, required)
  - `:time_max` — End of availability window (DateTime, required)
  - `:timezone` — Timezone for returned slots (e.g. `"America/New_York"`)
  """
  @spec get_booking_availability(String.t(), String.t(), map()) ::
          {:ok, list(map())} | {:error, Error.t()}
  def get_booking_availability(token, profile_id, %{time_min: _, time_max: _} = params) do
    query = %{
      timeMin: DateTime.to_iso8601(params.time_min),
      timeMax: DateTime.to_iso8601(params.time_max),
      timezone: params[:timezone] || "UTC"
    }

    with {:ok, body} <-
           Client.get(token, "/booking/profiles/#{profile_id}/availability", params: query) do
      {:ok, body["slots"] || body["records"] || []}
    end
  end

  def get_booking_availability(_token, _id, _),
    do: {:error, Error.invalid_params("`:time_min` and `:time_max` are required")}

  defp camelize_params(kw), do: Enum.map(kw, fn {k, v} -> {camelize(k), v} end)
  defp camelize(key) when is_atom(key), do: key |> Atom.to_string() |> camelize()

  defp camelize(str) when is_binary(str) do
    [first | rest] = String.split(str, "_")
    first <> Enum.map_join(rest, "", &String.capitalize/1)
  end
end
