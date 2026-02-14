defmodule Jido.Tools.Weather.Geocode do
  @moduledoc """
  Geocodes a location string to latitude/longitude coordinates.

  Uses OpenStreetMap's Nominatim API for geocoding.
  Supports city/state, addresses, zipcodes, and other location formats.
  """

  alias Jido.Action.Error

  use Jido.Action,
    name: "weather_geocode",
    description: "Convert a location string to lat,lng coordinates",
    category: "Weather",
    tags: ["weather", "location", "geocode"],
    vsn: "1.0.0",
    schema: [
      location: [
        type: :string,
        required: true,
        doc: "Location as city/state, address, zipcode, or place name"
      ]
    ]

  @deadline_key :__jido_deadline_ms__

  @impl Jido.Action
  def run(%{location: location}, context) do
    url = "https://nominatim.openstreetmap.org/search"

    req_options = [
      method: :get,
      url: url,
      params: %{
        q: location,
        format: "json",
        limit: 1
      },
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/json"
      }
    ]

    with {:ok, req_options} <- apply_deadline_timeout(req_options, context) do
      try do
        response = Req.request!(req_options)
        transform_result(response.status, response.body, location)
      rescue
        e ->
          {:error,
           Error.execution_error("Geocoding HTTP error: #{Exception.message(e)}", %{
             type: :geocode_http_error,
             reason: e
           })}
      end
    end
  end

  defp transform_result(200, [result | _], _location) do
    lat = parse_coordinate(result["lat"])
    lng = parse_coordinate(result["lon"])

    {:ok,
     %{
       latitude: lat,
       longitude: lng,
       coordinates: "#{lat},#{lng}",
       display_name: result["display_name"]
     }}
  end

  defp transform_result(200, [], location) do
    {:error,
     Error.execution_error("No geocoding results found for location: #{location}", %{
       type: :geocode_no_results,
       reason: %{location: location}
     })}
  end

  defp transform_result(status, body, _location) do
    {:error,
     Error.execution_error("Geocoding API error (#{status})", %{
       type: :geocode_request_failed,
       status: status,
       reason: %{status: status, body: body}
     })}
  end

  defp parse_coordinate(value) when is_binary(value) do
    {float, _} = Float.parse(value)
    Float.round(float, 4)
  end

  defp parse_coordinate(value) when is_float(value), do: Float.round(value, 4)
  defp parse_coordinate(value) when is_integer(value), do: value / 1

  defp apply_deadline_timeout(req_options, context) do
    case context[@deadline_key] do
      deadline_ms when is_integer(deadline_ms) ->
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now

        if remaining <= 0 do
          {:error,
           Error.timeout_error("Execution deadline exceeded before geocode request dispatch", %{
             deadline_ms: deadline_ms,
             now_ms: now
           })}
        else
          {:ok, put_receive_timeout(req_options, remaining)}
        end

      _ ->
        {:ok, req_options}
    end
  end

  defp put_receive_timeout(req_options, remaining) do
    case Keyword.get(req_options, :receive_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 ->
        Keyword.put(req_options, :receive_timeout, min(timeout, remaining))

      _ ->
        Keyword.put(req_options, :receive_timeout, remaining)
    end
  end
end
