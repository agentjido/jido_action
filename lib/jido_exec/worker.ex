defmodule Jido.Exec.Worker do
  @moduledoc false

  alias Jido.Exec.{Controller, Telemetry}

  @doc false
  @spec invoke(Controller.call(), (-> term())) :: {:ok, term()} | {:error, Exception.t()}
  def invoke(call, work) do
    with {:ok, task} <- start(call, work) do
      ref = task.ref

      receive do
        {^ref, result} ->
          finish(task)
          {:ok, result}

        {:DOWN, ^ref, :process, worker, reason} ->
          error =
            Jido.Action.Error.internal_error("Action execution process exited", %{reason: reason})

          Telemetry.fail_worker(call.controller, worker, error)
          {:error, error}
      end
    else
      {:error, reason} ->
        {:error,
         Jido.Action.Error.internal_error("Execution process could not start", %{
           reason: reason,
           retry: false
         })}
    end
  end

  @doc false
  @spec start(Controller.call(), (-> term()), :action | :compound) ::
          {:ok, Task.t()} | {:error, term()}
  def start(call, work, kind \\ :action) do
    parent = Telemetry.parent()

    task =
      Task.Supervisor.async_nolink(
        call.supervisor,
        fn ->
          # Links keep the worker group observable after supervisor death.
          # Register compounds before any nested Action starts, so their exits
          # can stop the call while ordinary Action failures remain collectible.
          Process.link(call.controller)
          if kind == :compound, do: send(call.controller, {:compound, self()})
          Process.group_leader(self(), call.group_leader)
          Telemetry.with_context(call.controller, parent, work)
        end,
        shutdown: :brutal_kill
      )

    {:ok, task}
  rescue
    error -> {:error, {:error, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec finish(Task.t()) :: :ok
  def finish(%Task{ref: ref, pid: pid} = task) do
    # A result can arrive before the Task exits. Keep the Task boundary before
    # a continuation or the next invocation starts.
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Task.shutdown(task, :brutal_kill)
    end

    Process.demonitor(ref, [:flush])
    :ok
  end
end
