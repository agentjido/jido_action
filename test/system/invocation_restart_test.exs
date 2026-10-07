defmodule JidoActionTest.System.InvocationRestartTest do
  use ExUnit.Case, async: false

  @moduletag :system
  @moduletag timeout: 30_000

  @result_prefix "INVOCATION_RESTART_RESULT="

  @child_source """
  Application.ensure_all_started(:jido_action)
  [phase | arguments] = System.argv()

  result =
    case {phase, arguments} do
      {"first", []} ->
        JidoActionTest.Fixtures.Execution.InvocationRestart.run_first()

      {"second", [encoded]} ->
        payload = encoded |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()
        JidoActionTest.Fixtures.Execution.InvocationRestart.run_second(payload)
    end

  encoded = result |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
  IO.puts("#{@result_prefix}" <> encoded)
  """

  test "a second VM rebuilds a partial Flow from portable receipts" do
    first = run_vm("first", [])

    assert first.result ==
             {:ok,
              %{
                items: [
                  %{index: 0, value: :same},
                  %{index: 1, value: :same},
                  %{index: 2, value: :same}
                ]
              }, [{:restart_effect, 0}, {:restart_effect, 1}, {:restart_effect, 2}]}

    assert Enum.sort(first.executed) == [{:vm_one, 0}, {:vm_one, 1}, {:vm_one, 2}]
    assert map_size(first.receipts) == 2

    transfer = Map.take(first, [:definition, :call_data, :receipts])
    refute contains_live_runtime_value?(transfer)
    refute contains_native_workflow?(transfer)

    encoded = transfer |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    second = run_vm("second", [encoded])

    assert second.result == first.result
    assert second.executed == [{:vm_two, 1}]
    assert second.receipt_count == 3
  end

  defp run_vm(phase, arguments) do
    executable = System.find_executable("elixir")

    paths =
      :code.get_path()
      |> Enum.map(&(&1 |> to_string() |> Path.expand()))
      |> Enum.filter(&(Path.basename(&1) == "ebin" and File.dir?(&1)))
      |> Enum.flat_map(&["-pa", &1])

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: paths ++ ["-e", @child_source, "--", phase | arguments],
        cd: File.cwd!(),
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"ERL_FLAGS", ~c"+S 2:2 +SDcpu 1 +SDio 1"}
        ]
      ])

    try do
      collect_vm(port, [], System.monotonic_time(:millisecond) + 12_000)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_vm(port, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect_vm(port, [data | output], deadline)

      {^port, {:exit_status, 0}} ->
        output
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> decode_result()

      {^port, {:exit_status, status}} ->
        flunk(
          "fresh VM exited with status #{status}:\n#{IO.iodata_to_binary(Enum.reverse(output))}"
        )
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:os_pid, pid} = Port.info(port, :os_pid)
        System.cmd(System.find_executable("kill"), ["-KILL", Integer.to_string(pid)])
        flunk("fresh VM timed out:\n#{IO.iodata_to_binary(Enum.reverse(output))}")
    end
  end

  defp decode_result(output) do
    [_, encoded] = Regex.run(~r/^#{@result_prefix}(.*)$/m, output)
    encoded |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()
  end

  defp contains_live_runtime_value?(value) when is_pid(value) or is_reference(value), do: true
  defp contains_live_runtime_value?(value) when is_port(value) or is_function(value), do: true

  defp contains_live_runtime_value?(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.any?(fn {key, item} ->
      contains_live_runtime_value?(key) or contains_live_runtime_value?(item)
    end)
  end

  defp contains_live_runtime_value?(value) when is_list(value),
    do: Enum.any?(value, &contains_live_runtime_value?/1)

  defp contains_live_runtime_value?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_live_runtime_value?/1)

  defp contains_live_runtime_value?(_value), do: false

  defp contains_native_workflow?(%Runic.Workflow{}), do: true

  defp contains_native_workflow?(value) when is_map(value),
    do:
      value
      |> Map.to_list()
      |> Enum.any?(fn {key, item} ->
        contains_native_workflow?(key) or contains_native_workflow?(item)
      end)

  defp contains_native_workflow?(value) when is_list(value),
    do: Enum.any?(value, &contains_native_workflow?/1)

  defp contains_native_workflow?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_native_workflow?/1)

  defp contains_native_workflow?(_value), do: false
end
