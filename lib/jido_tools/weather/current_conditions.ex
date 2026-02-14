defmodule Jido.Tools.Weather.CurrentConditions do
  @moduledoc """
  Gets current weather conditions from nearby NWS observation stations.

  First gets the list of observation stations for a location, then fetches
  the latest conditions from the nearest station using ReqTool architecture.
  """

  alias Jido.Action.Error

  use Jido.Action,
    name: "weather_current_conditions",
    description: "Get current weather conditions from nearest NWS observation station",
    category: "Weather",
    tags: ["weather", "current", "conditions", "nws"],
    vsn: "1.0.0",
    schema: [
      observation_stations_url: [
        type: :string,
        required: true,
        doc: "NWS observation stations URL from LocationToGrid action"
      ]
    ]

  @deadline_key :__jido_deadline_ms__

  @impl Jido.Action
  def run(params, context) do
    with {:ok, stations} <- get_observation_stations(params[:observation_stations_url], context) do
      get_current_conditions(List.first(stations), context)
    end
  end

  defp get_observation_stations(stations_url, context) do
    req_options = [
      method: :get,
      url: stations_url,
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/geo+json"
      }
    ]

    with {:ok, req_options} <- apply_deadline_timeout(req_options, context) do
      try do
        response = Req.request!(req_options)

        case response do
          %{status: 200, body: body} ->
            stations =
              body["features"]
              |> Enum.map(fn feature ->
                %{
                  id: feature["properties"]["stationIdentifier"],
                  name: feature["properties"]["name"],
                  url: feature["id"]
                }
              end)

            {:ok, stations}

          %{status: status, body: body} ->
            {:error,
             Error.execution_error("Failed to get observation stations (#{status})", %{
               type: :observation_stations_request_failed,
               status: status,
               reason: %{status: status, body: body}
             })}
        end
      rescue
        e ->
          {:error,
           Error.execution_error(
             "HTTP error getting observation stations: #{Exception.message(e)}",
             %{
               type: :observation_stations_http_error,
               reason: e
             }
           )}
      end
    end
  end

  defp get_current_conditions(%{url: station_url}, context) do
    observations_url = "#{station_url}/observations/latest"

    req_options = [
      method: :get,
      url: observations_url,
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/geo+json"
      }
    ]

    with {:ok, req_options} <- apply_deadline_timeout(req_options, context) do
      try do
        response = Req.request!(req_options)

        case response do
          %{status: 200, body: body} ->
            props = body["properties"]

            conditions = %{
              station: props["station"],
              timestamp: props["timestamp"],
              temperature: format_measurement(props["temperature"]),
              dewpoint: format_measurement(props["dewpoint"]),
              wind_direction: format_measurement(props["windDirection"]),
              wind_speed: format_measurement(props["windSpeed"]),
              wind_gust: format_measurement(props["windGust"]),
              barometric_pressure: format_measurement(props["barometricPressure"]),
              sea_level_pressure: format_measurement(props["seaLevelPressure"]),
              visibility: format_measurement(props["visibility"]),
              max_temperature_last_24_hours:
                format_measurement(props["maxTemperatureLast24Hours"]),
              min_temperature_last_24_hours:
                format_measurement(props["minTemperatureLast24Hours"]),
              precipitation_last_hour: format_measurement(props["precipitationLastHour"]),
              precipitation_last_3_hours: format_measurement(props["precipitationLast3Hours"]),
              precipitation_last_6_hours: format_measurement(props["precipitationLast6Hours"]),
              relative_humidity: format_measurement(props["relativeHumidity"]),
              wind_chill: format_measurement(props["windChill"]),
              heat_index: format_measurement(props["heatIndex"]),
              cloud_layers: props["cloudLayers"],
              text_description: props["textDescription"]
            }

            {:ok, conditions}

          %{status: status, body: body} ->
            {:error,
             Error.execution_error("Failed to get current conditions (#{status})", %{
               type: :current_conditions_request_failed,
               status: status,
               reason: %{status: status, body: body}
             })}
        end
      rescue
        e ->
          {:error,
           Error.execution_error(
             "HTTP error getting current conditions: #{Exception.message(e)}",
             %{
               type: :current_conditions_http_error,
               reason: e
             }
           )}
      end
    end
  end

  defp get_current_conditions(nil, _context) do
    {:error,
     Error.execution_error("No observation stations available", %{
       type: :observation_stations_empty,
       reason: :no_observation_stations
     })}
  end

  defp format_measurement(%{"value" => nil}), do: nil

  defp format_measurement(%{"value" => value, "unitCode" => unit_code}) do
    %{value: value, unit: parse_unit_code(unit_code)}
  end

  defp format_measurement(nil), do: nil

  defp parse_unit_code("wmoUnit:" <> unit), do: unit
  defp parse_unit_code(unit), do: unit

  defp apply_deadline_timeout(req_options, context) do
    case context[@deadline_key] do
      deadline_ms when is_integer(deadline_ms) ->
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now

        if remaining <= 0 do
          {:error,
           Error.timeout_error(
             "Execution deadline exceeded before current conditions request dispatch",
             %{
               deadline_ms: deadline_ms,
               now_ms: now
             }
           )}
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
