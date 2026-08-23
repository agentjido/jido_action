defmodule Jido.Flow.ErrorTaggerContractTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error
  alias Jido.Flow.{Choice, Iterator, Node, Reduce, Ref, State}
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Compiler.ErrorTagger
  alias Jido.Flow.Compiler.TargetContext
  alias JidoTest.TestActions.{Add, Multiply}

  test "keeps target phase and ownership details for every Flow element" do
    for {owner, input_phase, execution_phase, output_phase, details} <- owners() do
      assert {:error, input_error} =
               ErrorTagger.tag_target_validation_error(
                 {:error, Error.validation_error("invalid", %{source: :target})},
                 :input,
                 owner
               )

      assert input_error.message == "invalid"
      assert Map.take(input_error.details, Map.keys(details)) == details
      assert input_error.details.phase == input_phase

      for {phase, tagged_phase} <- [execution: execution_phase, output: output_phase] do
        assert {:error, tagged} =
                 ErrorTagger.tag_target_error(
                   {:error, Error.execution_error("failed", %{source: :target})},
                   phase,
                   owner
                 )

        assert tagged.message == "failed"
        assert Map.take(tagged.details, Map.keys(details)) == details
        assert tagged.details.phase == tagged_phase
      end
    end
  end

  test "keeps successful and non-exception target results unchanged" do
    for {owner, _input_phase, _execution_phase, _output_phase, _details} <- owners() do
      assert {:ok, :value} ==
               ErrorTagger.tag_target_validation_error({:ok, :value}, :input, owner)

      assert {:ok, :value} == ErrorTagger.tag_target_error({:ok, :value}, :execution, owner)
      assert {:error, :reason} == ErrorTagger.tag_target_error({:error, :reason}, :output, owner)
    end
  end

  test "keeps non-exception validation reasons and retry policy" do
    for {owner, input_phase, _execution_phase, _output_phase, details} <- owners() do
      assert {:error, tagged} =
               ErrorTagger.tag_target_validation_error({:error, :invalid}, :input, owner)

      assert tagged.message == "invalid"
      assert Map.take(tagged.details, Map.keys(details)) == details
      assert tagged.details.phase == input_phase
    end

    {iterator_owner, _input_phase, _execution_phase, _output_phase, _details} =
      owners() |> List.last()

    assert {:error, tagged} =
             ErrorTagger.tag_target_error(
               {:error, Error.execution_error("retry", %{retry: false})},
               :execution,
               iterator_owner
             )

    assert tagged.details.retry == false
  end

  defp owners do
    node = Node.new!(name: "step", action: Add)

    choice =
      Choice.new!(
        name: "choice",
        options: [
          [
            name: "selected",
            condition: Jido.Flow.Condition.eq(Ref.value(1), Ref.value(1)),
            action: Add
          ]
        ],
        fallback: [action: Multiply]
      )

    map = FlowMap.new!(name: "map", collection: Ref.value([]), action: Add)

    reduce =
      Reduce.new!(
        name: "reduce",
        collection: Ref.value([]),
        initial: Ref.value(%{}),
        action: Add
      )

    iterator =
      Iterator.new!(
        name: "iterate",
        action: Add,
        state: State.new!(schema: [], initial: %{}, update: Ref.body_result()),
        completion: Jido.Flow.Condition.eq(Ref.value(true), Ref.value(true)),
        max_iterations: 1
      )

    item = %{item_index: 3, item_id: "item-id"}

    [
      {TargetContext.node(node), :step_input, :step_execution, :step_output,
       %{node: "step", action: Add}},
      {TargetContext.choice(choice, hd(choice.options)), :choice_target_input,
       :choice_target_execution, :choice_target_output,
       %{node: "choice", option: "selected", target: Add}},
      {TargetContext.map(map, item), :map_target_input, :map_target_execution, :map_target_output,
       %{node: "map", target: Add, item_index: 3, item_id: "item-id"}},
      {TargetContext.reduce(reduce, item), :reduce_target_input, :reduce_target_execution,
       :reduce_target_output, %{node: "reduce", target: Add, item_index: 3, item_id: "item-id"}},
      {TargetContext.iterator(iterator, 4, "iteration-id", 5), :iterate_body_input,
       :iterate_body_execution, :iterate_body_output,
       %{
         node: "iterate",
         target: Add,
         iteration_index: 4,
         iteration_id: "iteration-id",
         state_revision: 5
       }}
    ]
  end
end
