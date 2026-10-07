defmodule JidoActionTest.Exec.ActionWorkerReplyTest do
  # Large reply traces run without concurrent compiler and memory tests.
  use ExUnit.Case, async: false

  alias Jido.Action.Error
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step}

  defmodule LargeExtras do
    @behaviour Jido.Action

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
          Exec.run(target, params, %{}, task_supervisor: supervisor, timeout: 5_000)
        end)

      assert_receive {^ref, :ready, worker}, 1_000
      monitor = Process.monitor(worker)

      try do
        assert :erlang.trace(worker, true, [:send, {:tracer, self()}]) == 1
        send(worker, {ref, :release})

        assert_receive {:trace, ^worker, :send, {reply_ref, reply}, recipient}
                       when is_reference(reply_ref) and recipient == reply_ref,
                       1_000

        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

        result = Task.await(caller)
        assert_reply(reply, result, unquote(kind), unquote(mode))

        # All send traces must arrive before checking for another worker reply.
        delivered = :erlang.trace_delivered(:all)
        assert_receive {:trace_delivered, :all, ^delivered}, 1_000
        refute_received {:trace, ^worker, :send, {^reply_ref, _}, _}
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

  defp assert_reply(
         %Runic.Workflow.Runnable{
           status: :completed,
           result: %{
             value: %Jido.Exec.Flow.Payload{value: {:jido_flow_value, _, output, effects}}
           }
         },
         result,
         :flow,
         :success
       ) do
    assert result == {:ok, output, effects}
    assert effects == Enum.to_list(1..100_000)
  end

  defp assert_reply(
         %Runic.Workflow.Runnable{status: :failed, error: worker_error} = reply,
         {:error, error},
         :flow,
         mode
       ) do
    assert :erts_debug.flat_size(reply) < 5_000
    assert worker_error == error
    assert_value(:error, error, mode)
  end

  defp assert_reply(reply, result, _kind, :success) do
    assert reply == result
    assert {:ok, %{mode: :success}, effects} = reply
    assert effects == Enum.to_list(1..100_000)
  end

  defp assert_reply(reply, result, kind, mode) do
    # Failed effects must not be copied out of the worker.
    assert :erts_debug.flat_size(reply) < 2_000

    worker_error =
      case {kind, reply} do
        {:flow, {:error, phase, error}} ->
          assert phase == if(mode == :output_error, do: :output, else: :execution)
          error

        {:action, {:error, error}} ->
          assert reply == result
          error
      end

    assert {:error, error} = result
    assert_value(:error, worker_error, mode)
    assert worker_error.__struct__ == error.__struct__
    assert worker_error.message == error.message

    if kind == :flow do
      assert error.details.phase ==
               if(mode == :output_error, do: :step_output, else: :step_execution)
    end
  end

  defp assert_value(:error, error, :execution_error),
    do: assert(error.__struct__ == Error.ExecutionFailureError)

  defp assert_value(:error, error, :output_error),
    do: assert(error.__struct__ == Error.InvalidInputError)
end
