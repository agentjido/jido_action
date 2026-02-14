defmodule Jido.Tools.Weather.Forecast do
  @moduledoc """
  Fetches detailed weather forecast data from the National Weather Service API using ReqTool.

  Uses the forecast URL obtained from LocationToGrid to get detailed period-by-period
  weather information including temperature, wind, and conditions.
  """

  use Jido.Action,
    name: "weather_forecast",
    description: "Get detailed weather forecast from NWS forecast URL",
    category: "Weather",
    tags: ["weather", "forecast", "nws"],
    vsn: "1.0.0",
    schema: [
      forecast_url: [
        type: :string,
        required: true,
        doc: "NWS forecast URL from LocationToGrid action"
      ],
      periods: [
        type: :integer,
        default: 14,
        doc: "Number of forecast periods to return (max available)"
      ],
      format: [
        type: {:in, [:detailed, :summary]},
        default: :summary,
        doc: "Level of detail in forecast"
      ]
    ]

  alias Jido.Action.Error

  @deadline_key :__jido_deadline_ms__

  @impl Jido.Action
  def run(%{forecast_url: forecast_url} = params, context) do
    req_options = [
      method: :get,
      url: forecast_url,
      headers: %{
        "User-Agent" => "jido_action/1.0 (weather tool)",
        "Accept" => "application/geo+json"
      }
    ]

    with {:ok, req_options} <- apply_deadline_timeout(req_options, context) do
      try do
        response = Req.request!(req_options)

        transform_result(%{
          request: %{url: forecast_url, method: :get, params: params},
          response: %{status: response.status, body: response.body, headers: response.headers}
        })
      rescue
        e -> {:error, "HTTP error: #{Exception.message(e)}"}
      end
    end
  end

  defp transform_result(%{request: %{params: params}, response: %{status: 200, body: body}}) do
    periods = body["properties"]["periods"]
    limited_periods = Enum.take(periods, params[:periods] || 14)

    formatted_periods =
      case params[:format] do
        :detailed -> format_detailed_periods(limited_periods)
        _ -> format_summary_periods(limited_periods)
      end

    result = %{
      forecast_url: params[:forecast_url],
      updated: body["properties"]["updated"],
      elevation: body["properties"]["elevation"],
      periods: formatted_periods,
      total_periods: length(periods)
    }

    {:ok, result}
  end

  defp transform_result(%{response: %{status: status, body: body}}) when status != 200 do
    {:error, "NWS forecast API error (#{status}): #{inspect(body)}"}
  end

  defp transform_result(_payload) do
    {:error, "Unexpected forecast response format"}
  end

  defp format_summary_periods(periods) do
    Enum.map(periods, fn period ->
      %{
        name: period["name"],
        temperature: period["temperature"],
        temperature_unit: period["temperatureUnit"],
        wind_speed: period["windSpeed"],
        wind_direction: period["windDirection"],
        short_forecast: period["shortForecast"],
        is_daytime: period["isDaytime"]
      }
    end)
  end

  defp format_detailed_periods(periods) do
    Enum.map(periods, fn period ->
      %{
        number: period["number"],
        name: period["name"],
        start_time: period["startTime"],
        end_time: period["endTime"],
        is_daytime: period["isDaytime"],
        temperature: period["temperature"],
        temperature_unit: period["temperatureUnit"],
        temperature_trend: period["temperatureTrend"],
        wind_speed: period["windSpeed"],
        wind_direction: period["windDirection"],
        icon: period["icon"],
        short_forecast: period["shortForecast"],
        detailed_forecast: period["detailedForecast"]
      }
    end)
  end

  defp apply_deadline_timeout(req_options, context) do
    case context[@deadline_key] do
      deadline_ms when is_integer(deadline_ms) ->
        now = System.monotonic_time(:millisecond)
        remaining = deadline_ms - now

        if remaining <= 0 do
          {:error,
           Error.timeout_error("Execution deadline exceeded before forecast request dispatch", %{
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
