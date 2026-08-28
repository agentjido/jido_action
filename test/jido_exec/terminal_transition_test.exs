defmodule JidoActionTest.Exec.TerminalTransitionTest do
  use JidoActionTest.Case, async: true

  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Exec
  alias Jido.Exec.Error.AsyncTimeoutError
  alias Jido.Exec.Transition
  alias Jido.Flow
  alias Jido.Flow.{Dynamic, Ref, Step}
  alias JidoActionTest.Fixtures.Actions.{Add, ExtrasAction}
  alias JidoActionTest.Fixtures.MathFlow

  defmodule ContinueToAdd do
    use Jido.Action,
      name: "terminal_continue_to_add",
      output_schema: Zoi.object(%{value: Zoi.string()})

    @impl true
    def run(%{value: value}, _context), do: {:continue, %{value: value, amount: 2}, Add}
  end

  defmodule ContinueToFlow do
    use Jido.Action, name: "terminal_continue_to_flow"

    @impl true
    def run(%{value: value}, _context), do: {:continue, %{value: value}, MathFlow}
  end

  defmodule ContinueToTarget do
    use Jido.Action, name: "terminal_continue_to_target"

    @impl true
    def run(%{input: input, target: target}, _context), do: {:continue, input, target}
  end

  defmodule ContinueToExtras do
    use Jido.Action, name: "terminal_continue_to_extras"

    @impl true
    def run(params, _context), do: {:continue, params, ExtrasAction}
  end

  defmodule ContinueForever do
    use Jido.Action, name: "terminal_continue_forever"

    @impl true
    def run(params, _context), do: {:continue, params, __MODULE__}
  end

  defmodule InvalidContinuationInput do
    use Jido.Action, name: "terminal_invalid_continuation_input"

    @impl true
    def run(_params, _context), do: {:continue, :not_a_map, Add}
  end

  defmodule InvalidContinuationTarget do
    use Jido.Action, name: "terminal_invalid_continuation_target"

    @impl true
    def run(_params, _context), do: {:continue, %{}, :not_an_executable}
  end

  defmodule ContextTarget do
    use Jido.Action, name: "terminal_context_target"

    @impl true
    def run(params, context), do: {:ok, Map.put(params, :trace_id, context.trace_id)}
  end

  defmodule ContinueWithContext do
    use Jido.Action, name: "terminal_continue_with_context"

    @impl true
    def run(params, _context), do: {:continue, params, ContextTarget}
  end

  defmodule TransitionData do
    use Jido.Action, name: "terminal_transition_data"

    @impl true
    def run(%{value: value}, context) do
      {:ok, Transition.new(%{value: value}, Add, __MODULE__, context)}
    end
  end

  defmodule ContinueToCountingTarget do
    use Jido.Action, name: "terminal_continue_to_counting_target"

    @impl true
    def run(params, _context) do
      {:continue, params, JidoActionTest.Exec.TerminalTransitionTest.CountingTarget}
    end
  end

  defmodule CountingTarget do
    def __jido_executable__ do
      if counter = Process.get(:terminal_transition_descriptor_counter) do
        Agent.update(counter, &(&1 + 1))
      end

      Jido.Executable.action(__MODULE__)
    end

    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(params, _context), do: {:ok, params}
  end

  defmodule Decision do
    use Jido.Action, name: "terminal_dynamic_decision"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule Expander do
    use Jido.Action, name: "terminal_dynamic_expander"

    @impl true
    def run(%{continue?: false, value: value}, _context), do: {:ok, %{value: value}}

    def run(%{continue?: true, target: target, value: value}, _context) do
      {:continue, %{value: value}, target}
    end
  end

  defmodule TransitionDataExpander do
    use Jido.Action, name: "terminal_transition_data_expander"

    @impl true
    def run(%{value: value}, context) do
      {:ok, Transition.new(%{value: value}, Add, __MODULE__, context)}
    end
  end

  defmodule ContinuingDecision do
    use Jido.Action, name: "terminal_continuing_decision"

    @impl true
    def run(params, _context), do: {:continue, params, Add}
  end

  describe "root Action transitions" do
    test "runs Action and Flow targets as the next executable" do
      assert Exec.run(ContinueToAdd, %{value: 3}) == {:ok, %{value: 5}}
      assert Exec.run(ContinueToFlow, %{value: 3}) == {:ok, %{value: 8}}
    end

    test "the final target owns output validation and extras" do
      assert Exec.run(ContinueToAdd, %{value: 3}) == {:ok, %{value: 5}}

      assert Exec.run(ContinueToExtras, %{value: 3}, %{trace_id: "trace"}) ==
               {:ok, %{value: 3}, %{trace_id: "trace"}}
    end

    test "passes the current Action context to the next executable" do
      assert Exec.run(ContinueWithContext, %{value: 3}, %{trace_id: "trace"}) ==
               {:ok, %{value: 3, trace_id: "trace"}}
    end

    test "resolves a continuation target exactly one time" do
      counter = start_supervised!({Agent, fn -> 0 end})
      Process.put(:terminal_transition_descriptor_counter, counter)
      on_exit(fn -> Process.delete(:terminal_transition_descriptor_counter) end)

      assert Exec.run(ContinueToCountingTarget, %{value: 3}) == {:ok, %{value: 3}}
      assert Agent.get(counter, & &1) == 1
    end

    test "rejects invalid continuation input and targets" do
      assert {:error, %ExecutionFailureError{message: "action returned an invalid continuation"}} =
               Exec.run(InvalidContinuationInput)

      assert {:error,
              %ExecutionFailureError{message: "action returned an invalid continuation target"}} =
               Exec.run(InvalidContinuationTarget)
    end

    test "stops an infinite continuation chain at one complete-call limit" do
      assert {:error,
              %ExecutionFailureError{
                message: "continuation limit exceeded",
                details: %{count: 3, max_continuations: 2}
              }} = Exec.run(ContinueForever, %{}, %{}, max_continuations: 2)
    end

    test "shares one continuation limit across Action and Flow boundaries" do
      flow = dynamic_flow!()

      input = %{
        input: %{continue?: true, value: 3, target: Add},
        target: flow
      }

      assert Exec.run(ContinueToTarget, input, %{}, max_continuations: 2) ==
               {:ok, %{value: 4}}

      assert {:error,
              %ExecutionFailureError{
                message: "continuation limit exceeded",
                details: %{count: 2, max_continuations: 1}
              }} = Exec.run(ContinueToTarget, input, %{}, max_continuations: 1)
    end

    test "the complete-call timeout covers the transition chain" do
      assert {:error, %Jido.Action.Error.TimeoutError{}} =
               Exec.run(ContinueForever, %{}, %{}, timeout: 10, max_continuations: 10_000)

      handle =
        Exec.run_async(ContinueForever, %{}, %{},
          timeout: :infinity,
          max_continuations: 10_000
        )

      assert {:error, %AsyncTimeoutError{}} = Exec.await(handle, 10)
    end
  end

  describe "terminal Dynamic transitions" do
    test "a terminal expander can close normally or select the next executable" do
      flow = dynamic_flow!()

      assert Exec.run(flow, %{continue?: false, value: 3, target: Add}) ==
               {:ok, %{value: 3}}

      assert Exec.run(flow, %{continue?: true, value: 3, target: Add}) ==
               {:ok, %{value: 4}}
    end

    test "a Dynamic decision cannot return a continuation" do
      flow = dynamic_flow!(decision: ContinuingDecision)

      assert {:error, %ExecutionFailureError{message: message}} =
               Exec.run(flow, %{continue?: false, value: 3, target: Add})

      assert message == "action continuation is not allowed from this Flow position"
    end

    test "normal Transition-shaped output stays domain data" do
      step_flow =
        Flow.new!(
          name: "transition_data_step",
          components: [
            Step.new!(name: "data", action: TransitionData, params: %{value: 3})
          ],
          output: Ref.result("data")
        )

      assert {:ok, %Transition{input: %{value: 3}, target: Add} = data} =
               Exec.run(step_flow, %{}, %{trace_id: "step"})

      assert {:ok, execution} = Exec.start(step_flow, %{}, %{trace_id: "step"})
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == {:ok, data}

      dynamic_flow = dynamic_flow!(expander: TransitionDataExpander)

      assert {:ok, %Transition{input: %{value: 3}, target: Add}} =
               Exec.run(
                 dynamic_flow,
                 %{continue?: false, value: 3, target: Add},
                 %{trace_id: "dynamic"}
               )
    end

    test "normal Steps cannot return continuations" do
      flow =
        Flow.new!(
          name: "non_dynamic_transition",
          components: [
            Step.new!(name: "continue", action: ContinueToAdd, params: %{value: 3})
          ],
          output: Ref.result("continue")
        )

      assert {:error, %ExecutionFailureError{message: message}} = Exec.run(flow)
      assert message == "action continuation is not allowed from this Flow position"
    end

    test "Dynamic must be the sole terminal component and exact Flow output" do
      dynamic = dynamic_component!()

      assert {:error, error} =
               Flow.new(
                 name: "dynamic_with_downstream",
                 components: [
                   dynamic,
                   Step.new!(name: "later", action: Add, params: %{value: 1}, after: ["next"])
                 ],
                 output: Ref.result("later")
               )

      assert Exception.message(error) == "Dynamic must be the sole terminal Flow component"

      assert {:error, error} =
               Flow.new(
                 name: "dynamic_with_wrapped_output",
                 components: [dynamic],
                 output: %{value: Ref.result("next", :value)}
               )

      assert Exception.message(error) == "Flow output must be the complete Dynamic result"
    end

    test "step-wise execution rejects a Flow with Dynamic" do
      assert {:error, error} = Exec.start(dynamic_flow!(), %{continue?: false, value: 3})
      assert Exception.message(error) == "step-wise execution does not support Dynamic"
    end
  end

  defp dynamic_flow!(overrides \\ []) do
    dynamic = dynamic_component!(overrides)

    Flow.new!(
      name: "terminal_dynamic_flow",
      components: [dynamic],
      output: Ref.result("next")
    )
  end

  defp dynamic_component!(overrides \\ []) do
    attrs =
      [
        name: "next",
        decision: Decision,
        expander: Expander,
        params: %{
          continue?: Ref.input(:continue?),
          target: Ref.input(:target),
          value: Ref.input(:value)
        }
      ]
      |> Keyword.merge(overrides)

    Dynamic.new!(attrs)
  end
end
