defmodule JidoTest.Tools.WeatherErrorContractTest do
  use JidoTest.ActionCase, async: false

  import Mimic

  alias Jido.Action.Error
  alias Jido.Tools.Weather.ByLocation
  alias Jido.Tools.Weather.CurrentConditions
  alias Jido.Tools.Weather.Forecast
  alias Jido.Tools.Weather.Geocode
  alias Jido.Tools.Weather.HourlyForecast
  alias Jido.Tools.Weather.LocationToGrid

  setup :set_mimic_global

  describe "weather leaf actions return structured errors" do
    test "LocationToGrid returns ExecutionFailureError for non-200 responses" do
      expect(Req, :request!, fn _opts ->
        %{status: 404, body: %{"detail" => "not found"}, headers: %{}}
      end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               LocationToGrid.run(%{location: "invalid"}, %{})

      assert error.details[:type] == :location_to_grid_request_failed
      assert %{status: 404} = error.details[:reason]
    end

    test "Forecast returns ExecutionFailureError for non-200 responses" do
      expect(Req, :request!, fn _opts ->
        %{status: 503, body: %{"detail" => "service unavailable"}, headers: %{}}
      end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               Forecast.run(%{forecast_url: "https://api.weather.gov/fail"}, %{})

      assert error.details[:type] == :forecast_request_failed
      assert %{status: 503} = error.details[:reason]
    end

    test "HourlyForecast returns ExecutionFailureError for non-200 responses" do
      expect(Req, :request!, fn _opts ->
        %{status: 500, body: %{"detail" => "internal error"}, headers: %{}}
      end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               HourlyForecast.run(%{hourly_forecast_url: "https://api.weather.gov/fail"}, %{})

      assert error.details[:type] == :hourly_forecast_request_failed
      assert %{status: 500} = error.details[:reason]
    end

    test "Geocode returns ExecutionFailureError when no results are found" do
      expect(Req, :request!, fn _opts ->
        %{status: 200, body: [], headers: %{}}
      end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               Geocode.run(%{location: "nowhere"}, %{})

      assert error.details[:type] == :geocode_no_results
      assert %{location: "nowhere"} = error.details[:reason]
    end

    test "CurrentConditions returns ExecutionFailureError when no stations are available" do
      expect(Req, :request!, fn _opts ->
        %{status: 200, body: %{"features" => []}, headers: %{}}
      end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               CurrentConditions.run(
                 %{observation_stations_url: "https://api.weather.gov/stations"},
                 %{}
               )

      assert error.details[:type] == :observation_stations_empty
      assert error.details[:reason] == :no_observation_stations
    end

    test "ByLocation wraps child failures into structured errors" do
      expect(Req, :request!, fn opts ->
        assert opts[:url] == "https://api.weather.gov/points/invalid"
        %{status: 404, body: %{"detail" => "not found"}, headers: %{}}
      end)

      assert {:error, %Error.ExecutionFailureError{} = error} =
               ByLocation.run(%{location: "invalid"}, %{})

      assert error.details[:type] == :grid_lookup_failed
      assert is_exception(error.details[:reason])
    end
  end
end
