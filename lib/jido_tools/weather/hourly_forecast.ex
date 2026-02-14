defmodule Jido.Tools.Weather.HourlyForecast do
  @moduledoc """
  Fetches hourly weather forecast data from the National Weather Service API using ReqTool.

  Provides hour-by-hour weather conditions for more detailed planning needs.
  """

  use Jido.Action,
    name: "weather_hourly_forecast",
    description: "Get hourly weather forecast from NWS API",
    category: "Weather",
    tags: ["weather", "hourly", "forecast", "nws"],
    vsn: "1.0.0",
    schema: [
      hourly_forecast_url: [
        type: :string,
        required: true,
        doc: "NWS hourly forecast URL from LocationToGrid action"
      ],
      hours: [
        type: :integer,
        default: 24,
        doc: "Number of hours to return (max 156)"
      ]
    ]

  alias Jido.Action.Error

  @deadline_key :__jido_deadline_ms__

  @impl Jido.Action
  def run(%{hourly_forecast_url: hourly_forecast_url} = params, context) do
    req_options = [
      method: :get,
      url: hourly_forecast_url,
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/geo+json"
      }
    ]

    with {:ok, req_options} <- apply_deadline_timeout(req_options, context) do
      try do
        response = Req.request!(req_options)

        transform_result(%{
          request: %{url: hourly_forecast_url, method: :get, params: params},
          response: %{status: response.status, body: response.body, headers: response.headers}
        })
      rescue
        e -> {:error, "HTTP error: #{Exception.message(e)}"}
      end
    end
  end

  defp transform_result(%{request: %{params: params}, response: %{status: 200, body: body}}) do
    periods = body["properties"]["periods"]
    limited_periods = Enum.take(periods, params[:hours] || 24)

    formatted_periods =
      Enum.map(limited_periods, fn period ->
        %{
          start_time: period["startTime"],
          end_time: period["endTime"],
          temperature: period["temperature"],
          temperature_unit: period["temperatureUnit"],
          wind_speed: period["windSpeed"],
          wind_direction: period["windDirection"],
          short_forecast: period["shortForecast"],
          probability_of_precipitation: get_in(period, ["probabilityOfPrecipitation", "value"]),
          relative_humidity: get_in(period, ["relativeHumidity", "value"]),
          dewpoint: get_in(period, ["dewpoint", "value"])
        }
      end)

    result = %{
      hourly_forecast_url: params[:hourly_forecast_url],
      updated: body["properties"]["updated"],
      periods: formatted_periods,
      total_periods: length(periods)
    }

    {:ok, result}
  end

  defp transform_result(%{response: %{status: status, body: body}}) when status != 200 do
    {:error, "NWS hourly forecast API error (#{status}): #{inspect(body)}"}
  end

  defp transform_result(_payload) do
    {:error, "Unexpected hourly forecast response format"}
  end

  defp apply_deadline_timeout(req_options, context) do
    case context[@deadline_key] do
      deadline_ms when is_integer(deadline_ms) ->
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now

        if remaining <= 0 do
          {:error,
           Error.timeout_error(
             "Execution deadline exceeded before hourly forecast request dispatch",
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
