Code.require_file("runtime.exs", __DIR__)

defmodule JidoActionTest.Property.AuthoringFixtures do
  @moduledoc false
  defmodule Inline do
    use Jido.Flow, name: "property_inline"

    flow do
      step "work", value <- input(:value) do
        {:ok, %{value: calculate(value)}, [value]}
      end

      output result("work")
    end

    defp calculate(value), do: value * 3 - 7
  end

  defmodule Extension do
    use Jido.Flow.Extension

    defmacro emit_value(name, value) do
      quote do
        step unquote(name),
          action: JidoActionTest.Property.Runtime.Emit,
          params: %{value: unquote(value)}
      end
    end
  end

  defmodule Extended do
    use Jido.Flow,
      name: "property_extended",
      extensions: [JidoActionTest.Property.AuthoringFixtures.Extension]

    flow do
      emit_value("work", input(:value))
      output result("work")
    end
  end
end
