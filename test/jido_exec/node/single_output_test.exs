defmodule Jido.Exec.Node.SingleOutputTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Jido.Exec.Fact, as: JidoFact
  alias Jido.Exec.Node.Action
  alias Jido.Instruction
  alias Runic.Workflow
  alias Runic.Workflow.{Invokable, PolicyDriver, SchedulerPolicy}
  alias Runic.Workflow.SingleOutput.{Context, Result}

  defmodule Echo do
    use Jido.Action, name: "single_output_echo"

    @impl true
    def run(params, _context), do: {:ok, params, [:echoed]}
  end

  defmodule Attempts do
    use Jido.Action, name: "single_output_attempts"

    @impl true
    def run(_params, %{counts: counts}) do
      attempt = :atomics.add_get(counts, 1, 1)
      {:ok, %{attempt: attempt}, [attempt]}
    end
  end

  test "the ordinary callback retains local values and explicit application metadata" do
    node = Action.new(Instruction.new!(target: Echo))
    reference = make_ref()
    input = JidoFact.local_root(%{reference: reference})
    metadata = Map.put(input.meta, :domain, %{source: :input})
    context = %Context{runtime: %{}, input_metadata: metadata}

    assert %Result{status: :value, value: encoded, metadata: output_metadata} =
             Action.run(node, input.value, context)

    assert JidoFact.value(Workflow.Fact.new(value: encoded, meta: output_metadata)) ==
             %{reference: reference}

    assert output_metadata.domain == %{source: :input}
    assert output_metadata.jido == %{identity_mode: :local, effects: [:echoed]}
  end

  test "after-hook retry accepts only the final callback effects and deferred hook" do
    counts = :atomics.new(1, [])
    owner = self()
    node = Action.new(Instruction.new!(target: Attempts), name: :attempts)

    after_hook = fn event, _ ->
      case JidoFact.value(event.result) do
        %{attempt: 1} ->
          {:error, :retry_after_hook}

        %{attempt: 2} ->
          {:apply,
           fn workflow ->
             send(owner, :accepted_hook)
             workflow
           end}
      end
    end

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.put_run_context(%{_global: %{counts: counts}})
      |> Map.put(:after_hooks, %{node.hash => [after_hook]})

    input = JidoFact.local_root(%{})
    {:ok, prepared} = Invokable.prepare(node, workflow, input)
    executed = PolicyDriver.execute(prepared, %SchedulerPolicy{max_retries: 1})
    assert executed.status == :completed
    assert :atomics.get(counts, 1) == 2
    assert executed.result.meta.jido.effects == [2]
    refute_received :accepted_hook
    _applied = Workflow.apply_runnable(workflow, executed)
    assert_received :accepted_hook
    refute_received :accepted_hook
  end
end
