defmodule InlineConsumer.Roles do
  use Jido.Flow, name: "inline_roles"
  require InlineConsumer.BodyMacro

  flow do
    step "seed" do
      action value <- input(:value), name: "step" do
        {:ok, %{value: adjust(value)}}
      end
    end

    map "mapped" do
      collection input(:items)

      action [value <- item(), seed <- result("seed", :value)], name: "map" do
        {:ok, %{value: adjust(value) + seed}}
      end
    end

    reduce "total" do
      collection result("mapped")
      initial %{value: 0}

      action [value <- item(:value), total <- accumulator(:value)], name: "reduce" do
        {:ok, %{value: total + adjust(value)}}
      end
    end

    choice "route" do
      option "selected" do
        condition input(:enabled)

        action value <- result("total", :value), name: "option" do
          {:ok, %{value: adjust(value)}}
        end
      end

      option "other" do
        condition false

        action value <- result("total", :value), name: "other" do
          {:ok, %{value: adjust(value)}}
        end
      end

      otherwise do
        action value <- result("total", :value), name: "fallback" do
          {:ok, %{value: adjust(value)}}
        end
      end
    end

    iterate "loop" do
      state [], initial: result("route")

      action value <- state(:value), name: "iterate" do
        {:ok, %{value: adjust(value)}}
      end

      update body_result()
      repeat 1
    end

    dispatch "next" do
      decision value <- result("loop", [:state, :value]), name: "decision" do
        {:ok, %{value: adjust(value)}}
      end

      expander %{value: value}, name: "expander" do
        {:ok, %{value: adjust(value)}}
      end
    end

    output result("next")
  end

  defp adjust(value), do: InlineConsumer.BodyMacro.increment(value)
end
