defmodule Jido.Tools.Weather.LocationToGrid do
  @moduledoc """
  Converts a location (coordinates) to NWS grid information using ReqTool.

  This is the first step in getting weather forecast data from the National Weather Service API.
  Returns grid coordinates and forecast URLs needed for detailed weather information.
  """

  alias Jido.Action.Error

  use Jido.Action,
    name: "weather_location_to_grid",
    description: "Convert location to NWS grid coordinates and forecast URLs",
    category: "Weather",
    tags: ["weather", "location", "nws"],
    vsn: "1.0.0",
    schema: [
      location: [
        type: :string,
        required: true,
        doc: "Location as 'lat,lng' coordinates"
      ]
    ]

  @impl Jido.Action
  def run(%{location: location} = params, _context) do
    url = "https://api.weather.gov/points/#{location}"

    req_options = [
      method: :get,
      url: url,
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/geo+json"
      }
    ]

    try do
      response = Req.request!(req_options)

      transform_result(%{
        request: %{url: url, method: :get, params: params},
        response: %{status: response.status, body: response.body, headers: response.headers}
      })
    rescue
      e ->
        {:error,
         Error.execution_error("HTTP error fetching grid location: #{Exception.message(e)}", %{
           type: :location_to_grid_http_error,
           reason: e
         })}
    end
  end

  defp transform_result(%{request: %{params: params}, response: %{status: 200, body: body}}) do
    properties = body["properties"]

    result = %{
      location: params[:location],
      grid: %{
        office: properties["gridId"],
        grid_x: properties["gridX"],
        grid_y: properties["gridY"]
      },
      urls: %{
        forecast: properties["forecast"],
        forecast_hourly: properties["forecastHourly"],
        forecast_grid_data: properties["forecastGridData"],
        observation_stations: properties["observationStations"]
      },
      timezone: properties["timeZone"],
      city: properties["relativeLocation"]["properties"]["city"],
      state: properties["relativeLocation"]["properties"]["state"]
    }

    {:ok, result}
  end

  defp transform_result(%{response: %{status: status, body: body}}) when status != 200 do
    {:error,
     Error.execution_error("NWS API error (#{status})", %{
       type: :location_to_grid_request_failed,
       status: status,
       reason: %{status: status, body: body}
     })}
  end

  defp transform_result(_payload) do
    {:error,
     Error.execution_error("Unexpected location-to-grid response format", %{
       type: :location_to_grid_response_invalid,
       reason: :unexpected_response_format
     })}
  end
end
