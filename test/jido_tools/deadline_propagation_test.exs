defmodule JidoTest.Tools.DeadlinePropagationTest do
  use JidoTest.ActionCase, async: false

  import Mimic

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Tools.ReqTool
  alias Jido.Tools.Weather.LocationToGrid
  alias JidoTest.TestActions.BasicAction

  setup :set_mimic_global
  setup :verify_on_exit!

  defmodule DeadlineReqAction do
    use ReqTool,
      name: "deadline_req_action",
      description: "Deadline-aware ReqTool test action",
      url: "https://example.com/deadline",
      method: :get,
      schema: []
  end

  defmodule SlowWorkflowAction do
    use Jido.Action,
      name: "deadline_slow_workflow_action",
      schema: [delay: [type: :non_neg_integer, default: 100]]

    @impl true
    def run(%{delay: delay}, _context) do
      Process.sleep(delay)
      {:ok, %{done: true}}
    end
  end

  defmodule DeadlineParallelWorkflow do
    use Jido.Tools.Workflow,
      name: "deadline_parallel_workflow",
      schema: [],
      workflow: [
        {:parallel, [name: "parallel", timeout_ms: 500, fail_on_error: true],
         [
           {:step, [name: "slow"], [{SlowWorkflowAction, [delay: 100]}]}
         ]}
      ]
  end

  test "exec fails fast when inherited deadline is already expired" do
    expired_deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, %Error.TimeoutError{} = error} =
             Exec.run(BasicAction, %{value: 1}, %{__jido_deadline_ms__: expired_deadline})

    assert Exception.message(error) =~ "Execution deadline exceeded before action dispatch"
  end

  test "exec propagates timeout budget into ReqTool receive_timeout" do
    expect(Req, :request!, fn opts ->
      assert is_integer(opts[:receive_timeout])
      assert opts[:receive_timeout] > 0
      assert opts[:receive_timeout] <= 30

      %{
        status: 200,
        body: %{"ok" => true},
        headers: %{"content-type" => "application/json"}
      }
    end)

    assert {:ok, _result} = Exec.run(DeadlineReqAction, %{}, %{}, timeout: 30, max_retries: 0)
  end

  test "ReqTool returns timeout error before HTTP dispatch when deadline is expired" do
    stub(Req, :request!, fn _opts ->
      flunk("request should not be dispatched when deadline has expired")
    end)

    expired_deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, %Error.TimeoutError{} = error} =
             DeadlineReqAction.run(%{}, %{__jido_deadline_ms__: expired_deadline})

    assert Exception.message(error) =~ "Execution deadline exceeded before HTTP request dispatch"
  end

  test "exec propagates timeout budget through weather request actions" do
    expect(Req, :request!, fn opts ->
      assert is_integer(opts[:receive_timeout])
      assert opts[:receive_timeout] > 0
      assert opts[:receive_timeout] <= 30

      %{
        status: 200,
        body: %{
          "properties" => %{
            "gridId" => "LOT",
            "gridX" => 76,
            "gridY" => 73,
            "forecast" => "https://api.weather.gov/gridpoints/LOT/76,73/forecast",
            "forecastHourly" => "https://api.weather.gov/gridpoints/LOT/76,73/forecast/hourly",
            "forecastGridData" => "https://api.weather.gov/gridpoints/LOT/76,73",
            "observationStations" => "https://api.weather.gov/gridpoints/LOT/76,73/stations",
            "timeZone" => "America/Chicago",
            "relativeLocation" => %{
              "properties" => %{
                "city" => "Chicago",
                "state" => "IL"
              }
            }
          }
        },
        headers: %{"content-type" => "application/geo+json"}
      }
    end)

    assert {:ok, _result} =
             Exec.run(
               LocationToGrid,
               %{location: "41.8781,-87.6298"},
               %{},
               timeout: 30,
               max_retries: 0
             )
  end

  test "workflow parallel timeout is capped by remaining deadline budget" do
    deadline = System.monotonic_time(:millisecond) + 20

    assert {:error, %Error.ExecutionFailureError{} = error} =
             DeadlineParallelWorkflow.run(%{}, %{__jido_deadline_ms__: deadline})

    assert %Error.TimeoutError{} = error.details[:reason]
  end

  test "workflow fails fast before dispatch when deadline is already expired" do
    expired_deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, %Error.TimeoutError{} = error} =
             DeadlineParallelWorkflow.run(%{}, %{__jido_deadline_ms__: expired_deadline})

    assert Exception.message(error) =~ "Execution deadline exceeded before parallel step dispatch"
  end
end
