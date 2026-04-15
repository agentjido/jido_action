defmodule Jido.ExecOtelTest do
  @moduledoc """
  Regression tests for OTel context propagation through Task.Supervisor in
  `Jido.Exec.execute_action_with_timeout/5`.

  When timeout > 0, the action runs in a spawned child task. Without explicit
  propagation, the OTel process-dictionary context does not flow into the task
  and any spans created inside the action become orphan root spans.
  """
  use ExUnit.Case, async: false

  alias Jido.Exec

  defmodule CaptureCtxAction do
    @moduledoc false
    use Jido.Action,
      name: "capture_ctx",
      description: "Captures the OTel context current in its own process",
      schema: []

    @impl true
    def run(_params, _context) do
      {:ok, %{ctx_in_action: OpenTelemetry.Ctx.get_current()}}
    end
  end

  describe "OTel context propagation through Task.Supervisor" do
    test "action sees the same OTel context as the caller (timeout > 0)" do
      caller_ctx =
        OpenTelemetry.Ctx.set_value(OpenTelemetry.Ctx.new(), :test_key, :test_value)

      OpenTelemetry.Ctx.attach(caller_ctx)

      assert {:ok, %{ctx_in_action: action_ctx}} =
               Exec.execute_action_with_timeout(CaptureCtxAction, %{}, %{}, 1_000)

      assert OpenTelemetry.Ctx.get_value(action_ctx, :test_key, nil) == :test_value
    end

    test "empty caller context still works (no-op propagation)" do
      OpenTelemetry.Ctx.attach(OpenTelemetry.Ctx.new())

      assert {:ok, %{ctx_in_action: action_ctx}} =
               Exec.execute_action_with_timeout(CaptureCtxAction, %{}, %{}, 1_000)

      assert is_map(action_ctx)
    end
  end
end
