defmodule JidoActionTest.Flow.Compiler.ErrorTaggerTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Flow.{Choice, Condition, Iterate, Reduce, Ref, Step}
  alias Jido.Flow.Compiler.ErrorTagger
  alias Jido.Flow.Compiler.TargetContext
  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Fixtures.Actions.{Add, Multiply}

  test "keeps target phase and ownership details for every Flow element" do
    for {owner, input_phase, execution_phase, output_phase, details} <- owners() do
      assert {:error, input_error} =
               ErrorTagger.tag_target_validation_error(
                 {:error,
                  Error.validation_error("invalid", %{source: :target, path: [:payload]})},
                 :input,
                 owner
               )

      assert input_error.message == "invalid"
      assert Map.take(input_error.details, Map.keys(details)) == details
      assert input_error.details.phase == input_phase
      assert input_error.details.path == [:payload]

      for {phase, tagged_phase} <- [execution: execution_phase, output: output_phase] do
        assert {:error, tagged} =
                 ErrorTagger.tag_target_error(
                   {:error,
                    Error.execution_error("failed", %{source: :target, path: [:payload]})},
                   phase,
                   owner
                 )

        assert tagged.message == "failed"
        assert Map.take(tagged.details, Map.keys(details)) == details
        assert tagged.details.phase == tagged_phase
        assert tagged.details.path == [:payload]
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

  test "wraps plain target exceptions without adding undeclared struct fields" do
    for {owner, _input_phase, execution_phase, _output_phase, details} <- owners() do
      exception = RuntimeError.exception("plain failure")

      assert {:error,
              %ExecutionFailureError{
                message: "plain failure",
                details: tagged_details
              } = tagged} =
               ErrorTagger.tag_target_error({:error, exception}, :execution, owner)

      assert tagged_details.exception == RuntimeError
      assert tagged_details.retry == false
      assert Map.take(tagged_details, Map.keys(details)) == details
      assert tagged_details.phase == execution_phase
      refute Map.has_key?(tagged, :unexpected)
    end
  end

  test "formats all validation reason shapes" do
    {owner, input_phase, _execution_phase, _output_phase, details} = owners() |> List.first()

    for {reason, message} <- [
          {"invalid input", "invalid input"},
          {{:invalid, 1}, "{:invalid, 1}"}
        ] do
      assert {:error, tagged} =
               ErrorTagger.tag_target_validation_error({:error, reason}, :input, owner)

      assert tagged.message == message
      assert Map.take(tagged.details, Map.keys(details)) == details
      assert tagged.details.phase == input_phase
      assert tagged.details.reason == reason
    end
  end

  defp owners do
    node = Step.new!(name: "step", action: Add)

    choice =
      Choice.new!(
        name: "choice",
        options: [
          [
            name: "selected",
            condition: Condition.eq(1, 1),
            action: Add
          ]
        ],
        fallback: [action: Multiply]
      )

    map = FlowMap.new!(name: "map", collection: [], action: Add)

    reduce =
      Reduce.new!(
        name: "reduce",
        collection: [],
        initial: %{},
        action: Add
      )

    iterator =
      Iterate.new!(
        name: "iterate",
        action: Add,
        state: Iterate.State.new!(schema: [], initial: %{}, update: Ref.body_result()),
        completion: Condition.eq(true, true),
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
