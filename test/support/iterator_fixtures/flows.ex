Code.ensure_compiled!(JidoActionTest.IteratorFixtures.Increment)
Code.ensure_compiled!(JidoActionTest.TestActions.Add)
Code.ensure_compiled!(JidoActionTest.TestActions.Multiply)

defmodule JidoActionTest.IteratorFixtures.ChildIterator do
  @moduledoc false
  use Jido.Flow, name: "child_iterator"

  flow do
    iterate "child" do
      state([], initial: %{count: 0})
      action(JidoActionTest.IteratorFixtures.Increment)
      params(%{count: state(:count), index: iteration_index()})
      update(%{count: body_result(:count)})
      repeat(1)
    end

    output(result("child"))
  end
end

defmodule JidoActionTest.IteratorFixtures.ChildMapReduce do
  @moduledoc false
  use Jido.Flow, name: "child_map_reduce"

  flow do
    map("enrich",
      collection: input(:items),
      action: JidoActionTest.TestActions.Add,
      params: %{value: item(:value), amount: 1}
    )

    reduce "summarize" do
      collection(result("enrich"))
      initial(%{value: 1})
      action(JidoActionTest.TestActions.Multiply)
      params(%{value: accumulator(:value), amount: item(:value)})
    end

    output(result("summarize"))
  end
end
