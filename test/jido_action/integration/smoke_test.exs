defmodule JidoActionTest.Integration.IncrementAction do
  @moduledoc false

  use Jido.Action,
    name: "integration_increment",
    schema: Zoi.object(%{value: Zoi.integer()}),
    output_schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value + 1}}
end

defmodule JidoActionTest.Integration.SimpleFlow do
  @moduledoc false

  use Jido.Flow, name: "integration_simple_flow"

  flow do
    step("first_increment",
      action: JidoActionTest.Integration.IncrementAction,
      params: %{value: input(:value)}
    )

    step("second_increment",
      action: JidoActionTest.Integration.IncrementAction,
      params: %{value: select(result("first_increment"), [:value])}
    )

    output(result("second_increment"))
  end
end

defmodule JidoActionTest.Integration.SmokeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Jido.Exec
  alias JidoActionTest.Integration.{IncrementAction, SimpleFlow}

  test "runs one Action through the public execution boundary" do
    assert {:ok, %{value: 42}} = Exec.run(IncrementAction, %{value: 41}, %{})
  end

  test "runs one Flow with two dependent Action steps" do
    assert {:ok, %{value: 42}} = Exec.run(SimpleFlow, %{value: 40}, %{})
  end
end
