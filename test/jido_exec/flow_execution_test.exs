defmodule Jido.Exec.FlowExecutionTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref

  alias JidoActionTest.Fixtures.Actions.{
    Add,
    ContextEcho,
    ErrorAction,
    FullAction,
    Multiply
  }

  defmodule EffectAction do
    use Jido.Action, name: "exec_v2_effect"

    @impl true
    def run(%{label: label, value: value}, _context), do: {:ok, %{value: value}, [label]}
  end

  test "independent branches join through Runic readiness" do
    flow =
      flow!(
        "branch_join",
        [
          step("left", Add, %{value: Ref.input(:value), amount: 1}),
          step("right", Multiply, %{value: Ref.input(:value), amount: 2}),
          step("join", FullAction, %{
            a: Ref.result("left", :value),
            b: Ref.result("right", :value)
          })
        ],
        Ref.result("join")
      )

    assert Exec.run(flow, %{value: 3}) == {:ok, %{a: 4, b: 6, result: 10}}
  end

  test "Flow parameters read input, prior results, and runtime context" do
    flow =
      flow!(
        "context",
        [step("echo", ContextEcho, %{value: Ref.input(:value)})],
        Ref.result("echo")
      )

    assert Exec.run(flow, %{value: 7}, %{trace_id: "trace-7"}) ==
             {:ok, %{value: 7, trace_id: "trace-7"}}
  end

  test "deferred effects use canonical component order after a branch join" do
    flow =
      flow!(
        "effects",
        [
          step("b", EffectAction, %{label: :b, value: Ref.input(:value)}),
          step("a", EffectAction, %{label: :a, value: Ref.input(:value)})
        ],
        %{a: Ref.result("a", :value), b: Ref.result("b", :value)}
      )

    assert Exec.run(flow, %{value: 5}) == {:ok, %{a: 5, b: 5}, [:a, :b]}
  end

  test "an Action failure stops dependent Flow work" do
    flow =
      flow!(
        "failure",
        [
          step("fail", ErrorAction, %{error_type: :validation}),
          step("blocked", Add, %{value: Ref.result("fail", :value), amount: 1})
        ],
        Ref.result("blocked")
      )

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "Validation error"}} =
             Exec.run(flow)
  end

  defp flow!(name, components, output) do
    Flow.new!(%{name: name, components: components, output: output})
  end

  defp step(name, action, params) do
    %{kind: :step, name: name, action: action, params: params}
  end
end
