defmodule Jido.Exec.Node.DispatchTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error.{ConfigurationError, ExecutionFailureError}
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Ref

  defmodule Decide do
    use Jido.Action, name: "dispatch_test_decide"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule Finalize do
    use Jido.Action, name: "dispatch_test_finalize"

    @impl true
    def run(%{value: value}, _context), do: {:ok, %{final: value}}
  end

  defmodule Expand do
    use Jido.Action, name: "dispatch_test_expand"

    @impl true
    def run(%{mode: "continue", value: value}, _context),
      do: {:continue, %{value: value}, Finalize}

    def run(%{mode: "bad_target", value: value}, _context), do: {:continue, %{value: value}, Enum}
    def run(%{mode: "refuse"}, _context), do: {:error, "expander refused", [:discarded]}
    def run(%{mode: "improper"}, _context), do: {:ok, %{done: true}, [:a | :b]}
  end

  test "an expander continuation runs the selected target" do
    assert Exec.run(flow(), %{mode: "continue", value: 4}) == {:ok, %{final: 4}}
  end

  test "an invalid continuation target fails the expander Runnable" do
    assert {:error, %ConfigurationError{details: details}} =
             Exec.run(flow(), %{mode: "bad_target", value: 1})

    assert details.target == Enum
    assert details.node == "next"
  end

  test "expander errors with discarded effects keep the Action reason" do
    assert {:error, %ExecutionFailureError{message: "expander refused"}} =
             Exec.run(flow(), %{mode: "refuse", value: 0})
  end

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
