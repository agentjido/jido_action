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

  @impl Jido.Action
  def run(%{location: location}, _context) do
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
end
