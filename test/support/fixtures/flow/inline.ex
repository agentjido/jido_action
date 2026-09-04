defmodule JidoActionTest.Fixtures.InlineGreetingFlow do
  @moduledoc false

  use Jido.Flow, name: "inline_greeting"

  flow do
    step "normalize", name <- input(:name) do
      {:ok, %{name: String.trim(name)}}
    end

    step "greet", name <- result("normalize", :name) do
      {:ok, %{message: "Hello, " <> name <> "!"}}
    end

    output(result("greet"))
  end
end

defmodule JidoActionTest.Fixtures.InlineBodyHelpers do
  @moduledoc false

  defmacro decorate(value) do
    quote do: "[" <> unquote(value) <> "]"
  end

  def step(name, value), do: %{name: name, value: value}
  def output(value), do: value
end

defmodule JidoActionTest.Fixtures.InlineLexicalFlow do
  @moduledoc false

  use Jido.Flow, name: "inline_lexical"

  alias String, as: Text
  import String, only: [upcase: 1]
  import JidoActionTest.Fixtures.InlineBodyHelpers, only: [decorate: 1]

  @prefix "before"
  defp before_step(value), do: value <> "!"

  flow do
    alias JidoActionTest.Fixtures.InlineBodyHelpers, as: Helpers

    step "lexical", name <- input(:name) do
      {:ok,
       %{
         value: name |> Text.trim() |> upcase() |> before_step() |> after_step() |> decorate(),
         module: __MODULE__,
         prefix: @prefix,
         qualified: Helpers.output(Helpers.step("body", name))
       }}
    end

    step "local_import", data <- result("lexical") do
      import JidoActionTest.Fixtures.InlineBodyHelpers, only: [step: 2, output: 1]
      {:ok, Map.put(data, :local_import, output(step("local", data.value)))}
    end

    output(result("local_import"))
  end

  @prefix "after"
  def current_prefix, do: @prefix
  defp after_step(value), do: value <> "?"
end
