defmodule JidoActionTest.Exec.ActionWorkerReplyTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}

  defmodule LargeExtras do
    @behaviour Jido.Action
    @behaviour Jido.Executable

    @impl true
    def __jido_executable__, do: Jido.Executable.action(__MODULE__)

    @impl true
    def validate_params(params), do: {:ok, params}

    @impl true
    def validate_output(%{mode: :output_error}),
      do: {:error, Error.validation_error("output rejected")}

    def validate_output(output), do: {:ok, output}

    @impl true
    def run(%{owner: owner, ref: ref, mode: mode}, _context) do
      send(owner, {ref, :ready, self()})

      receive do
        {^ref, :release} ->
          # Build the large value only in the worker, after tracing is ready.
          extras = Enum.to_list(1..100_000)

          if mode == :execution_error,
            do: {:error, Error.execution_error("work rejected"), extras},
            else: {:ok, %{mode: mode}, extras}
      end
    end
  end

  for kind <- [:action, :flow], mode <- [:success, :execution_error, :output_error] do
    test "#{kind} converts #{mode} extras before the worker sends its reply" do
      supervisor = start_supervised!(Task.Supervisor)
      ref = make_ref()
      params = %{owner: self(), ref: ref, mode: unquote(mode)}
      target = target(unquote(kind))

      caller =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Exec.run(target, params, %{}, task_supervisor: supervisor)
        end)

      assert_receive {^ref, :ready, worker}, 1_000
      monitor = Process.monitor(worker)

      try do
        assert :erlang.trace(worker, true, [:send, {:tracer, self()}]) == 1
        send(worker, {ref, :release})

        assert_receive {:trace, ^worker, :send, {reply_ref, ^worker, reply}, recipient}
                       when is_reference(reply_ref) and is_pid(recipient),
                       1_000

        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

        result = Task.await(caller)
        assert_reply(reply, result, unquote(kind), unquote(mode))

        # All send traces must arrive before checking for another worker reply.
        delivered = :erlang.trace_delivered(:all)
        assert_receive {:trace_delivered, :all, ^delivered}, 1_000
        refute_received {:trace, ^worker, :send, {^reply_ref, ^worker, _}, _}
      after
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
        Task.shutdown(caller, :brutal_kill)
      end
    end
  end

  defp target(:action), do: LargeExtras

  defp target(:flow) do
    Flow.new!(
      name: "large_extras",
      components: [Step.new!(name: "probe", action: LargeExtras, params: Ref.input([]))],
      output: Ref.result("probe")
    )
  end

  defp assert_reply(reply, result, :action, mode) do
    assert reply == result
    assert {status, value, extras} = reply
    assert length(extras) == 100_000
    assert hd(extras) == 1
    assert List.last(extras) == 100_000
    assert_value(status, value, mode)
  end

  defp assert_reply(reply, result, :flow, mode) do
    # One copy of the extras needs at least 200,000 words.
    assert :erts_debug.flat_size(reply) < 1_000

    if mode == :success do
      assert reply == {:ok, %{mode: :success}}
      assert result == reply
    else
      phase = if mode == :output_error, do: :output, else: :execution
      assert {:error, ^phase, error} = reply
      assert_value(:error, error, mode)
      assert {:error, public_error} = result
      assert public_error.__struct__ == error.__struct__
      assert public_error.message == error.message
    end
  end

  defp assert_value(:ok, %{mode: :success}, :success), do: :ok

  defp assert_value(:error, error, :execution_error),
    do: assert(error.__struct__ == Error.ExecutionFailureError)

  defp assert_value(:error, error, :output_error),
    do: assert(error.__struct__ == Error.InvalidInputError)
end
