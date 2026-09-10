defmodule JidoActionBench.SmallResult do
  @moduledoc false
  use Jido.Action, name: "benchmark_small_result"

  @impl true
  def run(params, context) do
    JidoActionBench.Fixtures.barrier(context)

    if params.fail do
      {:error, Jido.Action.Error.execution_error("benchmark failure")}
    else
      {:ok, %{value: 42}}
    end
  end
end

defmodule JidoActionBench.MemoryCases do
  @moduledoc false
  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Step, Subflow}
  alias JidoActionBench.{Child, Echo, Fixtures, SmallResult}

  @opts [task_supervisor: JidoActionBench.TaskSupervisor, max_concurrency: 1]

  def workloads do
    metadata_workloads() ++ input_workloads() ++ [ready_workload(), collector_workload()]
  end

  defp metadata_workloads do
    for shape <- [:step, :subflow],
        payload <- [:small, :large_list, :large_binary],
        workload <- metadata_cases(shape, payload),
        do: workload
  end

  defp metadata_cases(shape, payload) do
    meta = if payload == :small, do: %{}, else: %{notes: payload(payload)}

    components =
      for index <- 1..4 do
        attrs = [name: "s#{index}", params: %{value: Ref.input(:value)}, meta: meta]

        case shape do
          :step -> Step.new!([action: Echo] ++ attrs)
          :subflow -> Subflow.new!([flow: Child] ++ attrs)
        end
      end

    flow = Flow.new!(name: "metadata_#{shape}", components: components, output: Ref.result("s4"))
    {:ok, compiled} = Flow.compile(flow)
    digest = compiled.compilation_digest

    [
      %{
        id: "metadata/#{shape}/compile/#{payload}/4",
        setup: fn context -> context end,
        run: fn _ -> Flow.compile(flow) end,
        check: fn {:ok, compiled} -> expect!(compiled.compilation_digest, digest) end,
        retained: fn _, {:ok, compiled} -> %{compiled: compiled} end
      },
      execution_workload(
        "metadata/#{shape}/paused_continue/#{payload}/4",
        flow,
        %{value: 42},
        {:ok, %{value: 42}}
      )
    ]
  end

  defp input_workloads do
    for outcome <- [:success, :failure], payload <- [:small, :large_list] do
      flow =
        Flow.new!(
          name: "retention_#{outcome}",
          components: [
            Step.new!(
              name: "small_result",
              action: SmallResult,
              params: %{value: Ref.input(:value), fail: outcome == :failure}
            )
          ],
          output: Ref.result("small_result")
        )

      input = %{value: payload(payload), unused: payload(payload)}
      expected = if outcome == :success, do: {:ok, %{value: 42}}, else: :failure
      execution_workload("retention/#{outcome}/#{payload}", flow, input, expected)
    end
  end

  defp execution_workload(id, flow, input, expected) do
    %{
      id: id,
      setup: fn context -> start!(flow, input, context) end,
      run: &continue!/1,
      check: fn finished -> check_result!(Exec.result(finished), expected) end,
      retained: &execution_terms/2
    }
  end

  defp ready_workload do
    flow = Fixtures.graph(:parallel, 16)
    expected = {:ok, Map.new(1..16, &{"s#{&1}", %{value: 42}})}

    %{
      id: "inspection/ready/16",
      setup: fn context -> start!(flow, %{value: 42}, context) end,
      run: fn execution ->
        # Retain the last read only; earlier descriptions can be collected.
        work = Enum.reduce(1..100, [], fn _, _ -> Exec.ready(execution) end)
        {execution, work}
      end,
      check: fn {execution, work} ->
        try do
          expect!(length(work), 16)
          expect!(Enum.all?(work, &(&1.status == :ready)), true)
        after
          finished = continue!(execution)
          expect!(Exec.result(finished), expected)
        end
      end,
      retained: fn _, {execution, work} -> %{paused_execution: execution, work: work} end
    }
  end

  defp collector_workload do
    names = Enum.map(1..32, &"s#{&1}")
    producers = Enum.map(names, &Step.new!(name: &1, action: Echo, params: %{value: 42}))
    params = Map.new(names, &{&1, Ref.result(&1)})
    collector = Step.new!(name: "collect", action: Echo, params: params)

    flow =
      Flow.new!(
        name: "wide_collector",
        components: producers ++ [collector],
        output: Ref.result("collect")
      )

    expected = {:ok, Map.new(names, &{&1, %{value: 42}})}

    %{
      id: "dependencies/collector/32",
      setup: fn context ->
        {:ok, execution} = Exec.start(flow, %{}, context, @opts)
        {:ok, work, execution} = Exec.wave(execution)
        expect!(length(work), 32)
        Fixtures.barrier(context)
        execution
      end,
      run: &continue!/1,
      check: fn finished -> expect!(Exec.result(finished), expected) end,
      retained: &execution_terms/2
    }
  end

  defp start!(flow, input, context) do
    {:ok, execution} = Exec.start(flow, input, context, @opts)
    Fixtures.barrier(context)
    execution
  end

  defp continue!(execution) do
    {:ok, finished} = Exec.continue(execution)
    finished
  end

  defp execution_terms(paused, finished) do
    terms = %{
      paused_execution: paused,
      finished_execution: finished,
      result: Exec.result(finished)
    }

    if finished.status == :failed,
      do: Map.put(terms, :failure_records, finished.runnable_errors),
      else: terms
  end

  defp check_result!(
         {:error, %Jido.Action.Error.ExecutionFailureError{message: "benchmark failure"}},
         :failure
       ),
       do: :ok

  defp check_result!(actual, expected), do: expect!(actual, expected)

  defp expect!(actual, expected) do
    if actual != expected, do: raise("memory benchmark returned an incorrect result")
    :ok
  end

  defp payload(:small), do: 42
  defp payload(:large_list), do: Enum.to_list(1..5_000)
  defp payload(:large_binary), do: :binary.copy(<<42>>, 1_048_576)
end
