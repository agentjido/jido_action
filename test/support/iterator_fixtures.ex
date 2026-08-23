defmodule JidoTest.IteratorFixtures do
  @moduledoc false

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Condition, Iterator, Ref}

  @state_schema_recorder :jido_flow_iterator_runtime_state_schema_recorder

  alias JidoTest.IteratorFixtures.Increment

  def record_state_transform(value, _opts) do
    if owner = Process.whereis(@state_schema_recorder) do
      send(owner, {:state_schema_transform, value})
    end

    {:ok, Map.update!(value, :count, &(&1 + 100))}
  end

  def register_state_schema_recorder(pid) when is_pid(pid) do
    Process.register(pid, @state_schema_recorder)
  end

  def iterator_flow(opts) do
    action = Keyword.get(opts, :action, Increment)
    schema = Keyword.get(opts, :schema, [])

    input =
      Keyword.get(opts, :input, %{count: Ref.state(:count), index: Ref.iteration_index()})

    initial = Keyword.fetch!(opts, :initial)
    update = Keyword.get(opts, :update, %{count: Ref.body_result(:count)})
    completion = Keyword.fetch!(opts, :completion)
    max_iterations = Keyword.fetch!(opts, :max_iterations)

    iterator =
      Iterator.new!(
        name: :count,
        action: action,
        input: input,
        state: [schema: schema, initial: initial, update: update],
        completion: completion,
        max_iterations: max_iterations
      )

    Flow.new!(name: "iterator_runtime", nodes: [iterator], return: Ref.result(:count))
  end

  def eq(left, right), do: %Condition{operator: :eq, operands: [left, right]}
  def gte(left, right), do: %Condition{operator: :gte, operands: [left, right]}
  def error_details(error), do: error |> Map.to_list() |> Keyword.fetch!(:details)

  def run(flow, input \\ %{}, context \\ %{}), do: Exec.run(flow, input, context)
end
