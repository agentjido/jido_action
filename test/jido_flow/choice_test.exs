defmodule Jido.Flow.ChoiceTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Action.Error.InvalidInputError
  alias Jido.Flow.{Choice, Condition, Ref}
  alias JidoTest.TestActions.{Add, MissingRun, Multiply}

  describe "new/1" do
    test "builds an ordered case choice with a fixed fallback identity" do
      assert {:ok, choice} =
               Choice.new(
                 name: :route,
                 options: [
                   [
                     name: :priority,
                     condition: Condition.eq(Ref.input(:kind), :priority),
                     action: Add,
                     input: %{value: Ref.result(:classify, :value)}
                   ],
                   [
                     name: :bulk,
                     condition: Condition.in(Ref.input(:kind), [:bulk, :archive]),
                     action: Multiply,
                     input: %{value: Ref.result(:load_amount, :value)}
                   ]
                 ],
                 fallback: [action: Add, input: %{value: Ref.input(:value)}],
                 deps: [:prepared]
               )

      assert choice.name == "route"
      assert Enum.map(choice.options, & &1.name) == ["priority", "bulk"]
      assert choice.fallback.name == :fallback
      assert Choice.result_deps(choice) == ["classify", "load_amount", "prepared"]
    end

    test "rejects invalid choice shapes with useful paths" do
      valid_option = [name: :priority, condition: Condition.eq(1, 1), action: Add]
      valid_fallback = [action: Add]

      cases = [
        {%{name: :route, options: [], fallback: valid_fallback},
         "choice options must contain at least one option", []},
        {%{name: :route, options: [valid_option, valid_option], fallback: valid_fallback},
         "duplicate choice option name: \"priority\"", [:options, 1, :name]},
        {%{name: :route, options: [valid_option]}, "choice fallback is required", [:fallback]},
        {%{
           name: :route,
           options: [[name: :priority, condition: Condition.eq(1, 1), action: "bad"]],
           fallback: valid_fallback
         }, "choice option target must be a module atom", [:options, 0, :action]},
        {%{
           name: :route,
           options: [[name: :priority, condition: fn -> true end, action: Add]],
           fallback: valid_fallback
         }, "choice option condition must be a Jido.Flow.Condition", [:options, 0, :condition]},
        {%{name: :route, options: [valid_option], fallback: valid_fallback, unexpected: true},
         "unknown choice configuration key: :unexpected", [:unexpected]}
      ]

      for {attrs, expected_message, expected_path} <- cases do
        assert {:error, %InvalidInputError{message: ^expected_message, details: details}} =
                 Choice.new(attrs)

        assert details.path == expected_path
      end
    end

    test "keeps option paths on nested condition and name errors" do
      invalid_condition = %Condition{operator: :eq, operands: [1]}

      assert {:error, %InvalidInputError{message: message, details: details}} =
               Choice.new(
                 name: :route,
                 options: [
                   [name: :priority, condition: invalid_condition, action: Add]
                 ],
                 fallback: [action: Add]
               )

      assert message == "choice condition :eq must have exactly 2 operands"
      assert details.path == [:options, 0, :condition]

      assert {:error, %InvalidInputError{details: name_details}} =
               Choice.new(
                 name: :route,
                 options: [
                   [name: "", condition: Condition.eq(1, 1), action: Add]
                 ],
                 fallback: [action: Add]
               )

      assert name_details.path == [:options, 0, :name]
    end
  end

  test "collects all condition, target input, and explicit result dependencies" do
    choice =
      Choice.new!(
        name: :route,
        options: [
          [
            name: :priority,
            condition:
              Condition.all([
                Condition.eq(Ref.result(:classify, :kind), :priority),
                Condition.eq(Ref.result(:feature_flags, :enabled), true)
              ]),
            action: Add,
            input: %{value: [Ref.result(:priority_input, :value)]}
          ]
        ],
        fallback: [action: Multiply, input: %{value: Ref.result(:fallback_input, :value)}],
        deps: [:prepared, :classify]
      )

    assert Choice.result_deps(choice) == [
             "classify",
             "fallback_input",
             "feature_flags",
             "prepared",
             "priority_input"
           ]
  end

  test "checks targets in option order and then the fallback" do
    choice =
      Choice.new!(
        name: :route,
        options: [
          [name: :first, condition: Condition.eq(1, 1), action: Add],
          [name: :second, condition: Condition.eq(1, 1), action: MissingRun]
        ],
        fallback: [action: MissingRun]
      )

    assert {:error, %InvalidInputError{message: message, details: details}} = Choice.check(choice)
    assert message =~ "module is not a valid Jido action"
    assert details.option == "second"
    assert details.target == MissingRun

    fallback_only_failure =
      Choice.new!(
        name: :route,
        options: [[name: :first, condition: Condition.eq(1, 1), action: Add]],
        fallback: [action: MissingRun]
      )

    assert {:error, %InvalidInputError{details: fallback_details}} =
             Choice.check(fallback_only_failure)

    assert fallback_details.option == :fallback
    assert fallback_details.target == MissingRun
  end

  test "rejects runtime-only values in target input" do
    assert {:error, %InvalidInputError{message: message, details: details}} =
             Choice.new(
               name: :route,
               options: [
                 [
                   name: :priority,
                   condition: Condition.eq(1, 1),
                   action: Add,
                   input: %{owner: self()}
                 ]
               ],
               fallback: [action: Add]
             )

    assert message == "choice target input must be static module data"
    assert details.path == [:options, 0, :input]
  end
end
