defmodule Jido.Exec.Node.DispatchTest do
  use Covenant.Case, component: "jido_action.boundary", async: true

  alias Jido.Action.Error.{
    ConfigurationError,
    ExecutionFailureError,
    InvalidInputError
  }

  alias Jido.Exec
  alias Jido.Exec.Frame
  alias Jido.Flow
  alias Jido.Flow.Ref
  alias Runic.Workflow

  defmodule Decide do
    use Jido.Action, name: "dispatch_test_decide"

    @impl true
    def run(%{mode: "effects"} = params, _context), do: {:ok, params, [:decision]}
    def run(params, _context), do: {:ok, params}
  end

  defmodule Finalize do
    use Jido.Action, name: "dispatch_test_finalize"

    @impl true
    def run(%{value: value, effects: true}, _context), do: {:ok, %{final: value}, [:target]}
    def run(%{value: value}, _context), do: {:ok, %{final: value}}
  end

  defmodule Expand do
    use Jido.Action, name: "dispatch_test_expand"

    @impl true
    def run(%{mode: "continue", value: value}, _context),
      do: {:continue, %{value: value}, Finalize}

    def run(%{mode: "effects", value: value}, _context),
      do: {:continue, %{value: value, effects: true}, Finalize}

    def run(%{mode: "runtime_flow", value: value}, _context) do
      flow =
        Jido.Flow.new!(%{
          name: "dispatch_runtime_flow",
          components: [
            %{
              kind: :step,
              name: "finalize",
              action: Finalize,
              params: %{value: Jido.Flow.Ref.input(:value)}
            }
          ],
          output: Jido.Flow.Ref.result("finalize")
        })

      {:continue, %{value: value}, flow}
    end

    def run(%{mode: "invalid_input", value: value}, _context),
      do: {:continue, %{value: value}, JidoActionTest.Fixtures.Actions.Add}

    def run(%{mode: "invalid_output", value: value}, _context),
      do: {:continue, %{value: value}, JidoActionTest.Fixtures.Actions.InvalidOutput}

    def run(%{mode: "target_error", value: value}, _context),
      do: {:continue, %{value: value}, JidoActionTest.Fixtures.Actions.ErrorWithExtrasAction}

    def run(%{mode: "finish", value: value}, _context), do: {:ok, %{final: value}, [:expander]}
    def run(%{mode: "bad_target", value: value}, _context), do: {:continue, %{value: value}, Enum}
    def run(%{mode: "refuse"}, _context), do: {:error, "expander refused", [:discarded]}
    def run(%{mode: "improper"}, _context), do: {:ok, %{done: true}, [:a | :b]}
  end

  defmodule DecisionWithEffects do
    use Jido.Action, name: "dispatch_decision_effects"
    def run(params, _context), do: {:ok, params, [:decision]}
  end

  defmodule FinalOutput do
    use Jido.Action, name: "dispatch_final_output"
    def run(%{value: value}, _context), do: {:ok, %{final: value}, [:expanded, :expanded]}
  end

  @tag obligation: ["jido_action.boundary.I4", "jido_action.boundary.I8"]
  test "a final Dispatch result retains decision and expander effects" do
    flow =
      Flow.new!(%{
        name: "dispatch_final_effects",
        components: [
          %{
            kind: :dispatch,
            name: "next",
            decision: DecisionWithEffects,
            expander: FinalOutput,
            params: %{value: Ref.input(:value)}
          }
        ],
        output: Ref.result("next")
      })

    assert Exec.run(flow, %{value: 4}) == {:ok, %{final: 4}, [:decision, :expanded, :expanded]}
  end

  @tag obligation: "jido_action.boundary.I8"
  test "an expander continuation runs the selected target" do
    assert Exec.run(flow(), %{mode: "continue", value: 4}) == {:ok, %{final: 4}}
  end

  @tag obligation: "jido_action.boundary.I8"
  test "an expander continuation runs a runtime Flow target" do
    assert Exec.run(flow(), %{mode: "runtime_flow", value: 4}) == {:ok, %{final: 4}}
  end

  @tag obligation: ["jido_action.boundary.I4", "jido_action.boundary.I8"]
  test "an Action continuation uses a native Call and keeps ordered effects" do
    {completed, observation} =
      flow()
      |> Exec.compile!()
      |> Workflow.execute(Jido.Exec.Fact.local_value(Frame.new(%{mode: "effects", value: 4})))

    assert Exec.result(completed, observation) == {:ok, %{final: 4}, [:decision, :target]}
    nodes = Multigraph.vertices(completed.graph)
    assert Enum.count(nodes, &is_struct(&1, Runic.Workflow.Call)) == 1
    assert Enum.count(nodes, &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)) == 1
    assert Enum.count(nodes, &is_struct(&1, Jido.Exec.Node.Dispatch.Finish)) == 1
  end

  @tag obligation: "jido_action.boundary.I8"
  test "an Action continuation keeps local parent and target values" do
    value = {self(), make_ref(), fn -> :local end}
    assert Exec.run(flow(), %{mode: "continue", value: value}) == {:ok, %{final: value}}
  end

  @tag obligation: "jido_action.boundary.I8"
  test "different input occurrences use their own Action parameters" do
    definition = Exec.compile!(flow())
    first_input = Jido.Exec.Fact.local_value(Frame.new(%{mode: "continue", value: 1}))
    second_input = Jido.Exec.Fact.local_value(Frame.new(%{mode: "continue", value: 2}))
    {first, first_scope} = Workflow.execute(definition, first_input)
    {second, second_scope} = Workflow.execute(first, second_input)

    assert Exec.result(first, first_scope) == {:ok, %{final: 1}}
    assert Exec.result(second, second_scope) == {:ok, %{final: 2}}

    occurrences =
      Enum.filter(
        Multigraph.vertices(second.graph),
        &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
      )

    assert length(occurrences) == 2
    assert length(Enum.uniq_by(occurrences, & &1.hash)) == 2
  end

  @tag obligation: "jido_action.boundary.I8"
  test "a direct expander result does not create a Call" do
    {completed, observation} =
      flow()
      |> Exec.compile!()
      |> Workflow.execute(Jido.Exec.Fact.local_value(Frame.new(%{mode: "finish", value: 4})))

    assert Exec.result(completed, observation) == {:ok, %{final: 4}, [:expander]}
    refute Enum.any?(Multigraph.vertices(completed.graph), &is_struct(&1, Runic.Workflow.Call))
  end

  @tag obligation: [
         "jido_action.boundary.I1",
         "jido_action.boundary.I3",
         "jido_action.boundary.I8"
       ]
  test "selected Action validation failures keep their Flow location" do
    for {mode, value, context} <- [
          {"invalid_input", "bad", "Action"},
          {"invalid_output", 4, "Action output"}
        ] do
      assert {:error, %InvalidInputError{details: details}} =
               Exec.run(flow(), %{mode: mode, value: value})

      assert details.node == "next"
      assert details.node_path == ["next"]
      assert details.context == context
    end
  end

  @tag obligation: ["jido_action.boundary.I2", "jido_action.boundary.I8"]
  test "selected Action failures return no executable effects" do
    assert {:error, %ExecutionFailureError{details: %{node: "next", reason: :bad_with_extras}}} =
             Exec.run(flow(), %{mode: "target_error", value: 4})
  end

  @tag obligation: "jido_action.boundary.I8"
  test "an invalid continuation target fails the expander Runnable" do
    assert {:error, %ConfigurationError{details: details}} =
             Exec.run(flow(), %{mode: "bad_target", value: 1})

    assert details.target == Enum
    assert details.node == "next"
  end

  @tag obligation: "jido_action.boundary.I8"
  test "expander errors with discarded effects keep the Action reason" do
    assert {:error, %ExecutionFailureError{message: "expander refused"}} =
             Exec.run(flow(), %{mode: "refuse", value: 0})
  end

  @tag obligation: "jido_action.boundary.I8"
  test "expander effects must be a proper list" do
    assert {:error, %ExecutionFailureError{details: %{reason: :invalid_effects}}} =
             Exec.run(flow(), %{mode: "improper", value: 0})
  end

  defp flow do
    Flow.new!(%{
      name: "dispatch_test",
      components: [
        %{
          kind: :dispatch,
          name: "next",
          decision: Decide,
          expander: Expand,
          params: %{mode: Ref.input(:mode), value: Ref.input(:value)}
        }
      ],
      output: Ref.result("next")
    })
  end
end
