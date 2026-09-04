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

defmodule JidoActionTest.Fixtures.InlineParityFlow do
  @moduledoc false

  use Jido.Flow, name: "inline_parity", description: "All inline binding forms"

  flow do
    step "empty", [] do
      {:ok, %{ready: true}}
    end

    step "named", name <- input(:raw_name), after: ["empty"], meta: %{owner: "inline"} do
      {:ok, %{name: String.trim(name)}}
    end

    step "multiple", [name <- result("named", :name), prefix <- context(:prefix)],
      after: ["empty"],
      meta: %{purpose: "greeting"} do
      {:ok, %{message: prefix <> ", " <> name <> "!"}}
    end

    step "sole_map",
         %{"profile" => %{"city" => city}, "active" => true} <- input(:payload),
         after: ["multiple"] do
      {:ok, %{city: city}}
    end

    output(%{
      "empty" => result("empty"),
      "greeting" => result("multiple"),
      "profile" => result("sole_map")
    })
  end
end

defmodule JidoActionTest.Fixtures.InlineAuthoring do
  @moduledoc false

  alias Jido.Flow
  alias Jido.Flow.{Builder, Ref, Registry, Step}
  alias JidoActionTest.Fixtures.InlineParityFlow

  def direct_flow! do
    Flow.new!(
      name: "inline_parity",
      description: "All inline binding forms",
      components: [
        Step.new!(name: "empty", action: InlineParityFlow.step_action("empty"), params: %{}),
        Step.new!(
          name: "named",
          action: InlineParityFlow.step_action("named"),
          params: %{name: Ref.input(:raw_name)},
          after: ["empty"],
          meta: %{owner: "inline"}
        ),
        Step.new!(
          name: "multiple",
          action: InlineParityFlow.step_action("multiple"),
          params: %{name: Ref.result("named", :name), prefix: Ref.context(:prefix)},
          after: ["empty"],
          meta: %{purpose: "greeting"}
        ),
        Step.new!(
          name: "sole_map",
          action: InlineParityFlow.step_action("sole_map"),
          params: Ref.input(:payload),
          after: ["multiple"]
        )
      ],
      output: %{
        "empty" => Ref.result("empty"),
        "greeting" => Ref.result("multiple"),
        "profile" => Ref.result("sole_map")
      }
    )
  end

  def builder do
    Builder.new(name: "inline_parity", description: "All inline binding forms")
    |> Builder.step("empty", InlineParityFlow.step_action("empty"), %{})
    |> Builder.step(
      "named",
      InlineParityFlow.step_action("named"),
      %{name: Builder.input(:raw_name)},
      after: ["empty"],
      meta: %{owner: "inline"}
    )
    |> Builder.step(
      "multiple",
      InlineParityFlow.step_action("multiple"),
      %{name: Builder.result("named", :name), prefix: Builder.context(:prefix)},
      after: ["empty"],
      meta: %{purpose: "greeting"}
    )
    |> Builder.step(
      "sole_map",
      InlineParityFlow.step_action("sole_map"),
      Builder.input(:payload),
      after: ["multiple"]
    )
    |> Builder.output(%{
      "empty" => Builder.result("empty"),
      "greeting" => Builder.result("multiple"),
      "profile" => Builder.result("sole_map")
    })
  end

  def registry do
    Registry.new!(%{
      "actions/demo/empty/v1" => {:action, InlineParityFlow.step_action("empty")},
      "actions/demo/named/v1" => {:action, InlineParityFlow.step_action("named")},
      "actions/demo/multiple/v1" => {:action, InlineParityFlow.step_action("multiple")},
      "actions/demo/sole-map/v1" => {:action, InlineParityFlow.step_action("sole_map")},
      "schemas/empty/v1" => {:schema, []},
      "atoms/name" => {:atom, :name},
      "atoms/raw-name" => {:atom, :raw_name},
      "atoms/prefix" => {:atom, :prefix},
      "atoms/payload" => {:atom, :payload},
      "atoms/purpose" => {:atom, :purpose},
      "atoms/owner" => {:atom, :owner}
    })
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
