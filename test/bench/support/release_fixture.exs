defmodule JidoActionBench.ReleaseAction do
  use Jido.Action, name: "release_benchmark_action"

  @impl true
  def run(%{value: value, operation: :increment}, _), do: {:ok, %{value: value + 1}}
  def run(%{value: value, operation: :double}, _), do: {:ok, %{value: value * 2}}
end

defmodule JidoActionBench.ReleaseFlow do
  use Jido.Flow, name: "release_benchmark_flow"

  flow do
    step "first",
      action: JidoActionBench.ReleaseAction,
      params: %{value: input(:value), operation: :increment}

    step "second",
      action: JidoActionBench.ReleaseAction,
      params: %{value: result("first", :value), operation: :double}

    output result("second")
  end
end
