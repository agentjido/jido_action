defmodule JidoActionTest.Property.Execution.RevisionModel do
  @moduledoc false
  use PropCheck
  @behaviour PropCheck.StateM
  alias Jido.{Exec, Flow}
  alias Jido.Flow.Ref

  @key {__MODULE__, :session}

  defmodule Probe do
    use Jido.Action, name: "property_revision_probe"
    @impl true
    def run(%{name: name} = params, %{observer: observer, token: token} = context) do
      send(observer, {token, :work, name})

      if context[:gate] && Agent.get(context.gate, & &1) do
        send(observer, {token, :blocked, name, self()})

        receive do
          {^token, :release} -> :ok
        end
      end

      if params[:fail], do: {:error, {:revision_failure, name}}, else: {:ok, %{name: name}}
    end
  end

  @impl true
  def initial_state,
    do: %{
      started: false,
      remaining: [],
      old_count: 0,
      executed: [],
      failure: nil,
      failed: false,
      fuzz: false
    }

  def fuzz_state, do: %{initial_state() | fuzz: true}

  @impl true
  def command(%{started: false, fuzz: true}),
    do: {:call, __MODULE__, :start, [choose(2, 12), choose(-1, 11)]}

  def command(%{started: false}), do: {:call, __MODULE__, :start, [choose(2, 5)]}

  def command(state) do
    reads =
      [{:call, __MODULE__, :inspect_ready, []}, {:call, __MODULE__, :invalid, []}] ++
        if(state.fuzz, do: [{:call, __MODULE__, :foreign_token, []}], else: [])

    mutations =
      if state.remaining == [],
        do: [],
        else: [
          {:call, __MODULE__, :step, [elements(state.remaining)]},
          {:call, __MODULE__, :wave, []},
          {:call, __MODULE__, :complete, []}
        ]

    stale =
      if state.old_count == 0,
        do: [],
        else: [
          {:call, __MODULE__, :stale,
           [choose(0, state.old_count - 1), elements([:step, :wave, :continue])]},
          {:call, __MODULE__, :old_token, [choose(0, state.old_count - 1)]}
        ]

    competing =
      if state.fuzz and state.remaining != [],
        do: [{:call, __MODULE__, :compete, [elements(state.remaining)]}],
        else: []

    elements(reads ++ mutations ++ stale ++ competing)
  end

  @impl true
  def precondition(%{started: false}, {:call, _, :start, _}), do: true
  def precondition(%{started: false}, _), do: false
  def precondition(_, {:call, _, :start, _}), do: false
  def precondition(state, {:call, _, :step, [name]}), do: name in state.remaining

  def precondition(state, {:call, _, :compete, [name]}),
    do: state.fuzz and name in state.remaining

  def precondition(state, {:call, _, :wave, []}), do: state.remaining != []
  def precondition(state, {:call, _, :complete, []}), do: state.remaining != []
  def precondition(state, {:call, _, :stale, [index, _]}), do: index < state.old_count
  def precondition(state, {:call, _, :old_token, [index]}), do: index < state.old_count
  def precondition(_, _), do: true

  @impl true
  def next_state(state, _result, {:call, _, :start, [count]}) do
    %{state | started: true, remaining: names(count)}
  end

  def next_state(state, _result, {:call, _, :start, [count, index]}) do
    %{state | started: true, remaining: names(count), failure: failure(count, index)}
  end

  def next_state(state, _result, {:call, _, operation, [name]})
      when operation in [:step, :compete],
      do: advance(state, [name])

  def next_state(state, _result, {:call, _, operation, []})
      when operation in [:wave, :complete] do
    advance(state, state.remaining)
  end

  def next_state(state, _result, _call), do: state

  @impl true
  def postcondition(state, call, response) do
    expected = next_state(state, response, call)
    {:call, _, operation, args} = call

    events =
      case operation do
        op when op in [:step, :compete] -> args
        op when op in [:wave, :complete] -> state.remaining
        _ -> []
      end

    reason =
      case operation do
        :stale ->
          :stale_revision

        operation when operation in [:invalid, :old_token, :foreign_token] ->
          if(state.remaining == [], do: :not_running, else: :invalid_work_token)

        _ ->
          :ok
      end

    events_match =
      if operation in [:wave, :complete] and state.failure in state.remaining do
        # Ready work has no public admission order. With one worker, a failure
        # must be last; any distinct subset of the other ready work may precede it.
        List.last(response.events) == state.failure and
          length(response.events) == length(Enum.uniq(response.events)) and
          Enum.all?(response.events, &(&1 in state.remaining))
      else
        Enum.sort(response.events) == Enum.sort(events)
      end

    response.reason == reason and events_match and
      response.ready == Enum.sort(expected.remaining) and
      response.status == status(expected) and terminal_result?(expected, response.result)
  end

  def start(count), do: start_session(count, nil, false)
  def start(count, index), do: start_session(count, failure(count, index), true)

  defp start_session(count, failure, fuzz?) do
    token = make_ref()
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, gate} = Agent.start_link(fn -> false end)

    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "property_revisions",
        components:
          for(
            name <- names(count),
            do:
              JidoActionTest.FlowComponent.step!(
                name: name,
                action: Probe,
                params: %{name: name, fail: name == failure}
              )
          ),
        output: Map.new(names(count), &{&1, Ref.result(&1)})
      )

    {:ok, execution} =
      Exec.start(flow, %{}, %{observer: self(), token: token, gate: gate},
        max_concurrency: 1,
        task_supervisor: supervisor
      )

    foreign_token = make_ref()

    foreign =
      if fuzz? do
        {:ok, other} =
          Exec.start(flow, %{}, %{observer: self(), token: foreign_token, gate: gate},
            max_concurrency: 1,
            task_supervisor: supervisor
          )

        other
      end

    Process.put(@key, %{
      current: execution,
      old: [],
      token: token,
      foreign: foreign,
      foreign_token: foreign_token,
      supervisor: supervisor,
      gate: gate
    })

    response(:ok)
  end

  def foreign_token do
    session = Process.get(@key)
    [work | _] = Exec.ready(session.foreign)
    response(reason(Exec.step(session.current, work.token)))
  end

  def compete(name) do
    import ExUnit.Assertions
    session = Process.get(@key)
    work = Enum.find(Exec.ready(session.current), &(&1.component_path == [name]))
    Agent.update(session.gate, fn _ -> true end)
    caller = Task.async(fn -> Exec.step(session.current, work.token) end)

    try do
      token = session.token
      assert_receive {^token, :blocked, ^name, worker}, 5_000

      for operation <- [:step, :wave, :continue] do
        assert reason(apply(Exec, operation, [session.current])) == :operation_in_progress
      end

      assert reason(Exec.step(session.current, work.token)) == :operation_in_progress
      Agent.update(session.gate, fn _ -> false end)
      send(worker, {token, :release})
      {:ok, _, current} = Task.await(caller, 5_000)
      save(session, current)
      response(:ok)
    after
      Agent.update(session.gate, fn _ -> false end)
      Task.shutdown(caller, :brutal_kill)
    end
  end

  def inspect_ready, do: response(:ok)

  def invalid do
    session = Process.get(@key)
    response(reason(Exec.step(session.current, make_ref())))
  end

  def step(name) do
    session = Process.get(@key)
    work = Enum.find(Exec.ready(session.current), &(&1.component_path == [name]))
    {:ok, _work, current} = Exec.step(session.current, work.token)
    save(session, current)
    response(:ok)
  end

  def wave do
    session = Process.get(@key)
    {:ok, _work, current} = Exec.wave(session.current)
    save(session, current)
    response(:ok)
  end

  def complete do
    session = Process.get(@key)
    {:ok, current} = Exec.continue(session.current)
    save(session, current)
    response(:ok)
  end

  def old_token(index) do
    session = Process.get(@key)
    [work | _] = Exec.ready(Enum.at(session.old, index))
    response(reason(Exec.step(session.current, work.token)))
  end

  def stale(index, operation) do
    session = Process.get(@key)
    response(reason(apply(Exec, operation, [Enum.at(session.old, index)])))
  end

  # Each command run and each shrink attempt gets a new session. Complete any
  # paused lifecycle before removing local state. No helper process is needed.
  def cleanup do
    case Process.delete(@key) do
      nil ->
        :ok

      session ->
        try do
          Agent.update(session.gate, fn _ -> false end)
          Exec.continue(session.current)
          if session.foreign, do: Exec.continue(session.foreign)
        after
          try do
            Supervisor.stop(session.supervisor)
            Agent.stop(session.gate)
          after
            drain(session.token, [])
            drain(session.foreign_token, [])
          end
        end
    end
  end

  defp save(session, current),
    do: Process.put(@key, %{session | current: current, old: session.old ++ [session.current]})

  defp reason({:error, %Flow.Error.InvalidExecutionError{details: %{reason: reason}}}), do: reason

  defp reason(
         {:error, %Flow.Error.InvalidExecutionError{message: "flow execution is not running"}}
       ),
       do: :not_running

  defp reason(other), do: {:unexpected, other}

  defp response(reason) do
    session = Process.get(@key)

    %{
      reason: reason,
      events: drain(session.token, []),
      ready: Exec.ready(session.current) |> Enum.map(&hd(&1.component_path)) |> Enum.sort(),
      status: Exec.status(session.current),
      result: Exec.result(session.current)
    }
  end

  # Serial public calls above return only after callback messages were sent.
  defp drain(token, names) do
    receive do
      {^token, :work, name} -> drain(token, [name | names])
    after
      0 -> Enum.reverse(names)
    end
  end

  defp names(count), do: Enum.sort(for(index <- 1..count, do: "node_#{index}"))
  defp output(names), do: Map.new(names, &{&1, %{name: &1}})

  defp failure(_count, index) when index < 0, do: nil
  defp failure(count, index), do: Enum.at(names(count), rem(index, count))

  defp advance(state, events) do
    failed = state.failure in events

    %{
      state
      | remaining: if(failed, do: [], else: state.remaining -- events),
        failed: failed,
        old_count: state.old_count + 1,
        # A failed wave can admit any subset before its failing callback.
        # Retain only work known before that terminal transition.
        executed: if(failed, do: state.executed, else: events ++ state.executed)
    }
  end

  defp status(%{failed: true}), do: :failed
  defp status(%{remaining: []}), do: :succeeded
  defp status(_), do: :running

  defp terminal_result?(%{failed: true, failure: name}, result),
    do:
      match?(
        {:error,
         %Jido.Action.Error.ExecutionFailureError{details: %{reason: {:revision_failure, ^name}}}},
        result
      )

  defp terminal_result?(%{remaining: [], executed: names}, result),
    do: result == {:ok, output(names)}

  defp terminal_result?(_, _), do: true
end
