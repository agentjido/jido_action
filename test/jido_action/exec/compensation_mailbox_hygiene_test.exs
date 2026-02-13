defmodule JidoTest.Exec.CompensationMailboxHygieneTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec

  @moduletag :capture_log

  defmodule TimeoutCompensationAction do
    use Jido.Action,
      name: "timeout_compensation_mailbox_hygiene",
      compensation: [enabled: true, timeout: 20]

    @impl true
    def run(_params, _context), do: {:error, Error.execution_error("intentional failure")}

    @impl true
    def on_error(_params, _error, _context, _opts) do
      Process.sleep(200)
      {:ok, %{compensated: true}}
    end
  end

  defmodule CrashCompensationAction do
    use Jido.Action,
      name: "crash_compensation_mailbox_hygiene",
      compensation: [enabled: true, timeout: 100]

    @impl true
    def run(_params, _context), do: {:error, Error.execution_error("intentional failure")}

    @impl true
    def on_error(_params, _error, _context, _opts) do
      raise "compensation crashed"
    end
  end

  describe "compensation task cleanup" do
    test "does not leak monitor/result messages when compensation times out" do
      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{} = error} =
                 Exec.run(TimeoutCompensationAction, %{}, %{}, timeout: 20)

        assert Exception.message(error) =~ "Compensation timed out"

        Process.sleep(30)
        refute_receive _, 50
      end)
    end

    test "does not leak monitor/result messages when compensation crashes" do
      capture_log(fn ->
        assert {:error, %Error.ExecutionFailureError{} = error} =
                 Exec.run(CrashCompensationAction, %{}, %{}, timeout: 100)

        assert Exception.message(error) =~ "Compensation crashed for:"

        Process.sleep(30)
        refute_receive _, 50
      end)
    end
  end
end
