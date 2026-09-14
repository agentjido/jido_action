defmodule JidoActionTest.Authoring.Greeting.Normalize do
  use Jido.Action,
    name: "authoring_normalize_name",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{name: Zoi.string()})

  @impl true
  def run(%{name: name}, _context), do: {:ok, %{name: String.trim(name)}}
end

defmodule JidoActionTest.Authoring.Greeting.Greet do
  use Jido.Action,
    name: "authoring_greet",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()})

  @impl true
  def run(%{name: name}, %{prefix: prefix}), do: {:ok, %{message: prefix <> ", " <> name <> "!"}}
end

defmodule JidoActionTest.Authoring.Greeting.Flow do
  use Jido.Flow,
    name: "authoring_greeting",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{message: Zoi.string()})

  flow do
    step "normalize",
      action: JidoActionTest.Authoring.Greeting.Normalize,
      params: %{name: input(:name)}

    step "greet",
      action: JidoActionTest.Authoring.Greeting.Greet,
      params: %{name: result("normalize", :name)}

    output result("greet")
  end
end
