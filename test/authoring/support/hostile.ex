defmodule JidoActionTest.Authoring.Hostile.Watch do
  use Jido.Action, name: "authoring_watch"

  @impl true
  def run(params, context) do
    if observer = context[:observer], do: send(observer, {:hostile_action, params})
    {:ok, params}
  end
end

defmodule JidoActionTest.Authoring.Hostile.BadState do
  use Jido.Action, name: "authoring_bad_state"

  @impl true
  def run(_params, context) do
    if observer = context[:observer], do: send(observer, :bad_state_called)
    {:ok, %{count: "wrong type"}}
  end
end

defmodule JidoActionTest.Authoring.Hostile.ChoiceNonBoolean do
  use Jido.Flow, name: "authoring_non_boolean_choice"

  flow do
    choice "route" do
      option "selected",
        condition: input(:condition),
        action: JidoActionTest.Authoring.Hostile.Watch,
        params: %{branch: :selected}

      otherwise(
        action: JidoActionTest.Authoring.Hostile.Watch,
        params: %{branch: :fallback}
      )
    end

    output result("route")
  end
end

defmodule JidoActionTest.Authoring.Hostile.IterateInitial do
  use Jido.Flow, name: "authoring_bad_initial_state"

  flow do
    iterate "counter" do
      state Zoi.object(%{count: Zoi.integer()}), initial: %{count: input(:seed)}
      action JidoActionTest.Authoring.Hostile.Watch
      params %{count: state(:count)}
      update %{count: body_result(:count)}
      repeat 1
    end

    output %{counter: result("counter")}
  end
end

defmodule JidoActionTest.Authoring.Hostile.IterateReplacement do
  use Jido.Flow, name: "authoring_bad_replacement_state"

  flow do
    iterate "counter" do
      state Zoi.object(%{count: Zoi.integer()}), initial: %{count: 0}
      action JidoActionTest.Authoring.Hostile.BadState
      params %{count: state(:count)}
      update %{count: body_result(:count)}
      repeat 2
    end

    output %{counter: result("counter")}
  end
end
