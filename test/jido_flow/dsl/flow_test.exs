defmodule Jido.Flow.DSL.FlowTest.MixedFlow do
  @moduledoc false

  use Jido.Flow, name: "mixed_dsl"

  flow do
    step("load",
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: input(:value), amount: 1},
      meta: %{owner: "dsl"}
    )

    choice "route" do
      option "add" do
        condition(input(:kind) == :add)
        action(JidoActionTest.Fixtures.Actions.Add)
        params(%{value: result("load", :value), amount: 1})
      end

      otherwise(
        action: JidoActionTest.Fixtures.Actions.Multiply,
        params: %{value: result("load", :value), amount: 1}
      )
    end

    map("mapped",
      collection: input(:items),
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: item(:value), amount: 1},
      on_error: :collect_errors
    )

    reduce "reduced" do
      collection(result("mapped"))
      initial(%{value: 1})
      action(JidoActionTest.Fixtures.Actions.Multiply)
      params(%{value: accumulator(:value), amount: item(:value)})
    end

    iterate "loop" do
      state([], initial: %{count: 0})
      action(JidoActionTest.Fixtures.Actions.Add)
      params(%{value: state(:count), amount: 1})
      update(%{count: body_result(:value)})
      repeat(1)
    end

    output(result("loop"))
  end
end

defmodule Jido.Flow.DSL.FlowTest.InlineAndExistingFlow do
  @moduledoc false

  use Jido.Flow, name: "inline_and_existing"

  flow do
    step "inline", name <- input(:name) do
      {:ok, %{name: name}}
    end

    step "keyword",
      action: JidoActionTest.Fixtures.Actions.Add,
      params: %{value: 1, amount: 2}

    step "field_block" do
      action(JidoActionTest.Fixtures.Actions.Multiply)
      params(%{value: result("keyword", :value), amount: 2})
    end

    step "child",
      action: JidoActionTest.Fixtures.InlineGreetingFlow,
      params: result("inline")

    output(%{message: result("child", :message), value: result("field_block", :value)})
  end
end

defmodule Jido.Flow.DSL.FlowTest do
  use ExUnit.Case, async: true

  alias Jido.Flow.Choice
  alias Jido.Flow.Iterate
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Jido.Flow.Step

  test "inline Steps coexist with keyword Steps, field-block Steps, and Subflows" do
    module = Jido.Flow.DSL.FlowTest.InlineAndExistingFlow

    assert [%Step{}, %Step{}, %Step{}, %Jido.Flow.Subflow{}] = module.flow().components

    assert Jido.Exec.run(module, %{name: " Ada "}) ==
             {:ok, %{message: "Hello, Ada!", value: 6}}
  end

  test "the unchanged Spark forms lower directly to canonical records" do
    flow = Jido.Flow.DSL.FlowTest.MixedFlow.flow()

    assert [
             %Step{name: "load", params: %{amount: 1}, meta: %{owner: "dsl"}},
             %Choice{name: "route", after: []},
             %FlowMap{name: "mapped", on_error: :collect_errors},
             %Reduce{name: "reduced"},
             %Iterate{name: "loop", max_iterations: 1}
           ] = flow.components

    assert flow.output == Ref.result("loop")
  end

  test "a Flow module exposes only the required Flow and Action-compatible helpers" do
    module = Jido.Flow.DSL.FlowTest.MixedFlow

    for {name, arity} <- [
          __jido_executable__: 0,
          flow: 0,
          compiled: 0,
          name: 0,
          description: 0,
          schema: 0,
          output_schema: 0,
          validate_params: 1,
          validate_output: 1,
          run: 2
        ] do
      assert function_exported?(module, name, arity)
    end

    for name <- [
          :to_map,
          :validate,
          :validate_executable,
          :dependencies,
          :explain,
          :semantic_identity
        ] do
      refute function_exported?(module, name, 0)
    end
  end

  test "Flow output is required" do
    code = """
    defmodule MissingOutputFlow do
      use Jido.Flow, name: "missing_output"

      flow do
        step "add", action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}
      end
    end
    """

    assert_raise CompileError, ~r/Flow output is required/, fn -> Code.compile_string(code) end
  end

  test "an invalid Dispatch output points to the output declaration" do
    code = """
    defmodule InvalidDispatchOutputSourceFlow do
      use Jido.Flow, name: "invalid_dispatch_output_source"

      flow do
        dispatch("next",
          decision: JidoActionTest.Fixtures.Actions.Add,
          expander: JidoActionTest.Fixtures.Actions.Add,
          params: %{value: 1}
        )

        output(%{value: result("next")})
      end
    end
    """

    output_line =
      code
      |> String.split("\n")
      |> Enum.find_index(&String.contains?(&1, "output("))
      |> Kernel.+(1)

    error =
      assert_raise CompileError, ~r/Flow output must be the complete Dispatch result/, fn ->
        Code.compile_string(code)
      end

    assert error.line == output_line
  end

  test "a second Dispatch points to its declaration" do
    code = """
    defmodule DuplicateDispatchSourceFlow do
      use Jido.Flow, name: "duplicate_dispatch_source"

      flow do
        dispatch("first",
          decision: JidoActionTest.Fixtures.Actions.Add,
          expander: JidoActionTest.Fixtures.Actions.Add,
          params: %{}
        )

        dispatch("second",
          decision: JidoActionTest.Fixtures.Actions.Add,
          expander: JidoActionTest.Fixtures.Actions.Add,
          params: %{}
        )

        output(result("second"))
      end
    end
    """

    source_file = "duplicate_dispatch_source.ex"

    second_dispatch_line =
      code
      |> String.split("\n")
      |> Enum.find_index(&String.contains?(&1, "dispatch(\"second\""))
      |> Kernel.+(1)

    error =
      assert_raise CompileError, ~r/only one Dispatch component/, fn ->
        Code.compile_string(code, source_file)
      end

    assert error.file == source_file
    assert error.line == second_dispatch_line
  end

  test "Flow declaration macros reject duplicate and non-keyword options" do
    duplicate_options = """
    defmodule DuplicateStepOptionsFlow do
      use Jido.Flow, name: "duplicate_step_options"

      flow do
        step("add",
          action: JidoActionTest.Fixtures.Actions.Add,
          action: JidoActionTest.Fixtures.Actions.Add
        )

        output(result("add"))
      end
    end
    """

    assert_raise CompileError, ~r/duplicate Flow declaration field: :action/, fn ->
      Code.compile_string(duplicate_options)
    end

    non_keyword_options = """
    defmodule NonKeywordStepOptionsFlow do
      use Jido.Flow, name: "non_keyword_step_options"

      flow do
        step("add", :invalid)
        output(result("add"))
      end
    end
    """

    assert_raise CompileError, ~r/Flow declaration options must be a keyword list/, fn ->
      Code.compile_string(non_keyword_options)
    end
  end

  test "a Flow module in a Choice Action slot is a source-aware compile error" do
    code = """
    defmodule NestedChoiceTargetFlow do
      use Jido.Flow, name: "nested_choice_target"

      flow do
        choice "route" do
          option "nested" do
            condition(1 == 1)
            action(JidoActionTest.Fixtures.NestedFlow)
            params(%{value: 1})
          end

          otherwise action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}
        end

        output(result("route"))
      end
    end
    """

    error =
      assert_raise CompileError, ~r/wrong executable kind/, fn -> Code.compile_string(code) end

    assert error.line == 6
  end

  test "an invalid Choice fallback points to the otherwise declaration" do
    code = """
    defmodule InvalidChoiceFallbackTargetFlow do
      use Jido.Flow, name: "invalid_choice_fallback_target"

      flow do
        choice "route" do
          option "valid" do
            condition(1 == 1)
            action(JidoActionTest.Fixtures.Actions.Add)
            params(%{value: 1})
          end

          otherwise action: JidoActionTest.Fixtures.NestedFlow, params: %{value: 1}
        end

        output(result("route"))
      end
    end
    """

    source_file = "invalid_choice_fallback.ex"

    otherwise_line =
      code
      |> String.split("\n")
      |> Enum.find_index(&String.contains?(&1, "otherwise action:"))
      |> Kernel.+(1)

    error =
      assert_raise CompileError, ~r/wrong executable kind/, fn ->
        Code.compile_string(code, source_file)
      end

    assert error.file == source_file
    assert error.line == otherwise_line
  end

  test "output must be the last declaration" do
    code = """
    defmodule OutputBeforeStepFlow do
      use Jido.Flow, name: "output_before_step"

      flow do
        output(%{})
        step "add", action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}
      end
    end
    """

    assert_raise CompileError, ~r/output must be the final Flow declaration/, fn ->
      Code.compile_string(code)
    end
  end

  test "Choice requires options and a fallback" do
    no_options = """
    defmodule ChoiceWithoutOptionsFlow do
      use Jido.Flow, name: "choice_without_options"

      flow do
        choice "route" do
          otherwise action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}
        end

        output(result("route"))
      end
    end
    """

    assert_raise CompileError, ~r/choice must declare at least one option/, fn ->
      Code.compile_string(no_options)
    end

    no_fallback = """
    defmodule ChoiceWithoutFallbackFlow do
      use Jido.Flow, name: "choice_without_fallback"

      flow do
        choice "route" do
          option "yes",
            condition: 1 == 1,
            action: JidoActionTest.Fixtures.Actions.Add,
            params: %{value: 1}
        end

        output(result("route"))
      end
    end
    """

    assert_raise CompileError, ~r/choice must declare otherwise/, fn ->
      Code.compile_string(no_fallback)
    end
  end

  test "Iterate requires valid state and termination data" do
    cases = [
      {"""
       iterate "loop" do
         action(JidoActionTest.Fixtures.Actions.Add)
         params(%{value: 1})
         repeat(1)
       end
       """, "iterate must declare one state"},
      {"""
       iterate "loop" do
         state([], initial: %{})
         action(JidoActionTest.Fixtures.Actions.Add)
         params(%{value: 1})
         while(1 == 1)
       end
       """, "iterate max_iterations must be an integer"},
      {"""
       iterate "loop" do
         state([], initial: %{})
         action(JidoActionTest.Fixtures.Actions.Add)
         params(%{value: 1})
         repeat(1)
         max_iterations(1)
       end
       """, "iterate repeat must not set max_iterations"},
      {"""
       iterate "loop" do
         state([], initial: %{})
         action(JidoActionTest.Fixtures.Actions.Add)
         params(%{value: 1})
       end
       """, "iterate requires exactly one of while or repeat"}
    ]

    cases
    |> Enum.with_index()
    |> Enum.each(fn {{iterate, message}, index} ->
      code = """
      defmodule InvalidTerminationFlow#{index} do
        use Jido.Flow, name: "invalid_termination_#{index}"

        flow do
          #{iterate}
          output(result("loop"))
        end
      end
      """

      assert_raise CompileError, ~r/#{message}/, fn -> Code.compile_string(code) end
    end)
  end

  test "the lowerer reports invalid expressions and unavailable step modules" do
    invalid_expression = """
    defmodule InvalidOutputExpressionFlow do
      use Jido.Flow, name: "invalid_output_expression"

      flow do
        output(Date.utc_today())
      end
    end
    """

    assert_raise CompileError, ~r/unsupported Flow expression/, fn ->
      Code.compile_string(invalid_expression)
    end

    missing_module = """
    defmodule MissingStepModuleFlow do
      use Jido.Flow, name: "missing_step_module"

      flow do
        step "missing", action: Jido.Flow.NotARealModule, params: %{}
        output(result("missing"))
      end
    end
    """

    assert_raise CompileError, ~r/step action module could not be compiled/, fn ->
      Code.compile_string(missing_module)
    end
  end

  test "a valid while Iterate and scalar Step after lower without DSL shape changes" do
    code = """
    defmodule ValidWhileAndAfterFlow do
      use Jido.Flow, name: "valid_while_and_after"

      flow do
        step "first", action: JidoActionTest.Fixtures.Actions.Add, params: %{value: 1}

        step "second",
          action: JidoActionTest.Fixtures.Actions.Add,
          params: %{value: 1},
          after: "first"

        iterate "loop" do
          state([], initial: %{value: 0})
          action(JidoActionTest.Fixtures.Actions.Add)
          params(%{value: state(:value)})
          update(body_result())
          while(state(:value) < 1)
          max_iterations(2)
        end

        output(result("loop"))
      end
    end
    """

    [{module, _bytecode}] = Code.compile_string(code)

    assert [
             %Jido.Flow.Step{},
             %Jido.Flow.Step{after: ["first"]},
             %Jido.Flow.Iterate{}
           ] = module.flow().components

    assert %{[:components, "loop", :state] => %{line: line}} =
             module.__jido_flow_source_map__()

    assert is_integer(line)
  end

  test "invalid module configuration is a compile error" do
    code = """
    defmodule InvalidFlowConfiguration do
      use Jido.Flow, name: 123
      flow do
        output(%{})
      end
    end
    """

    assert_raise CompileError, ~r/Flow configuration validation failed/, fn ->
      Code.compile_string(code)
    end

    non_map_code = """
    defmodule NonMapFlowConfiguration do
      use Jido.Flow, :invalid
      flow do
        output(%{})
      end
    end
    """

    assert_raise CompileError, ~r/Flow configuration validation failed/, fn ->
      Code.compile_string(non_map_code)
    end
  end
end
