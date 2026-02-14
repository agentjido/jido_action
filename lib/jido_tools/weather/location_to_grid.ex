defmodule Jido.Tools.Weather.LocationToGrid do
  @moduledoc """
  Converts a location (coordinates) to NWS grid information using ReqTool.

  This is the first step in getting weather forecast data from the National Weather Service API.
  Returns grid coordinates and forecast URLs needed for detailed weather information.
  """

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

  alias Jido.Action.Error

  @deadline_key :__jido_deadline_ms__

  @impl Jido.Action
  def run(%{location: location} = params, context) do
    url = "https://api.weather.gov/points/#{location}"

    req_options = [
      method: :get,
      url: url,
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/geo+json"
      }
    ]

    with {:ok, req_options} <- apply_deadline_timeout(req_options, context) do
      try do
        response = Req.request!(req_options)

        transform_result(%{
          request: %{url: url, method: :get, params: params},
          response: %{status: response.status, body: response.body, headers: response.headers}
        })
      rescue
        e -> {:error, "HTTP error: #{Exception.message(e)}"}
      end
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
    {:error, "NWS API error (#{status}): #{inspect(body)}"}
  end

  defp transform_result(_payload) do
    {:error, "Unexpected response format"}
  end

  defp apply_deadline_timeout(req_options, context) do
    case context[@deadline_key] do
      deadline_ms when is_integer(deadline_ms) ->
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now

        if remaining <= 0 do
          {:error,
           Error.timeout_error("Execution deadline exceeded before grid lookup dispatch", %{
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
