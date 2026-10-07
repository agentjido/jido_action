defmodule Jido.Exec.PortableTest do
  use ExUnit.Case, async: false

  alias Jido.Exec

  defmodule BlockingAction do
    use Jido.Action, name: "exec_v2_portable_blocking"

    @impl true
    def run(_params, _context) do
      receive do
        :release -> {:ok, %{released: true}}
      end
    end
  end

  defmodule LocalOutputAction do
    use Jido.Action, name: "exec_v2_local_output"

    @impl true
    def run(_params, _context), do: {:ok, %{pid: self()}}
  end

  test "managed execution rejects process-local input before it starts" do
    runner = start_runner!()
    execution_id = unique_id()

    assert {:error, error} = Exec.start(runner, execution_id, BlockingAction, %{}, %{pid: self()})
    assert error.details.reason == :non_portable_durable_value
    assert error.details.type == :pid
    assert Runic.Runner.lookup(runner, execution_id) == nil
  end

  test "managed execution fails a process-local Action result before persistence" do
    runner = start_runner!()
    execution_id = unique_id()
    test_pid = self()

    assert {:ok, _worker} =
             Exec.start(runner, execution_id, LocalOutputAction, %{}, %{},
               hooks: [
                 on_failed: fn _runnable, error, _state ->
                   send(test_pid, {:local_output_failed, error})
                 end
               ]
             )

    assert_receive {:local_output_failed, error}, 1_000
    assert error.details.reason == :non_portable_durable_value
    assert error.details.type == :pid
  end

  defp start_runner! do
    runner = __MODULE__.Runner
    start_supervised!({Runic.Runner, name: runner})
    runner
  end

  defp unique_id, do: {:exec_v2_portable, System.unique_integer([:positive])}
end
