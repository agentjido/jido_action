defmodule JidoTest.Tools.WeatherRetryPolicyTest do
  use JidoTest.ActionCase, async: false

  import Mimic

  alias Jido.Tools.Weather
  alias Jido.Tools.Weather.ByLocation

  setup :set_mimic_global

  test "Weather.run/2 uses max_retries: 0 by default for internal orchestration" do
    expect(Jido.Exec, :run, fn Jido.Tools.Weather.ByLocation, _params, _context, opts ->
      assert Keyword.get(opts, :max_retries) == 0
      {:ok, %{forecast: "sunny"}}
    end)

    assert {:ok, %{forecast: "sunny"}} = Weather.run(%{format: :text}, %{})
  end

  test "Weather.run/2 allows explicit internal retry override via context" do
    expect(Jido.Exec, :run, fn Jido.Tools.Weather.ByLocation, _params, context, opts ->
      assert context[:__jido_internal_exec_opts__] == [max_retries: 2]
      assert Keyword.get(opts, :max_retries) == 2
      {:ok, %{forecast: "sunny"}}
    end)

    assert {:ok, %{forecast: "sunny"}} =
             Weather.run(%{format: :text}, %{__jido_internal_exec_opts__: [max_retries: 2]})
  end

  test "ByLocation.run/2 applies max_retries policy to internal Exec.run calls" do
    stub(Jido.Exec, :run, fn action, _params, _context, opts ->
      send(self(), {:exec_call, action, opts})

      case action do
        Jido.Tools.Weather.LocationToGrid ->
          {:ok,
           %{
             location: "x",
             city: "City",
             state: "ST",
             timezone: "UTC",
             grid: %{},
             urls: %{forecast: "https://api.weather.gov/forecast"}
           }}

        Jido.Tools.Weather.Forecast ->
          {:ok, %{periods: [], updated: nil}}
      end
    end)

    assert {:ok, _} = ByLocation.run(%{location: "x", format: :summary}, %{})

    assert_receive {:exec_call, Jido.Tools.Weather.LocationToGrid, first_opts}
    assert_receive {:exec_call, Jido.Tools.Weather.Forecast, second_opts}
    assert Keyword.get(first_opts, :max_retries) == 0
    assert Keyword.get(second_opts, :max_retries) == 0
  end

  test "ByLocation.run/2 preserves explicit internal retry override from context" do
    context = %{__jido_internal_exec_opts__: [max_retries: 1]}

    stub(Jido.Exec, :run, fn action, _params, received_context, opts ->
      send(self(), {:exec_call, action, received_context, opts})

      case action do
        Jido.Tools.Weather.LocationToGrid ->
          {:ok,
           %{
             location: "x",
             city: "City",
             state: "ST",
             timezone: "UTC",
             grid: %{},
             urls: %{forecast: "https://api.weather.gov/forecast"}
           }}

        Jido.Tools.Weather.Forecast ->
          {:ok, %{periods: [], updated: nil}}
      end
    end)

    assert {:ok, _} = ByLocation.run(%{location: "x", format: :summary}, context)

    assert_receive {:exec_call, Jido.Tools.Weather.LocationToGrid, ^context, first_opts}
    assert_receive {:exec_call, Jido.Tools.Weather.Forecast, ^context, second_opts}
    assert Keyword.get(first_opts, :max_retries) == 1
    assert Keyword.get(second_opts, :max_retries) == 1
  end
end
