defmodule JidoActionTest.Flow.DSL.FlowTest do
  use JidoActionTest.Case, async: true

  alias JidoActionTest.TestActions.{Add, EchoParamsAction, Multiply}

  test "executes the declarative Step syntax and infers the final output" do
    module = unique_module("DeclarativeStepFlow")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "declarative_step_flow"

        flow do
          step("added",
            action: unquote(Add),
            params: %{value: input(:value), amount: 2}
          )

          step("doubled",
            action: unquote(Multiply),
            params: %{value: select(result("added"), [:value]), amount: 3}
          )
        end
      end
    )

    assert {:ok, %{value: 21}} = Jido.Exec.run(module, %{value: 5}, %{})
    assert module.flow().return == Jido.Flow.Ref.result("doubled")
  end

  test "executes one complete declarative Flow" do
    module = unique_module("CompleteDeclarativeFlow")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "complete_declarative_flow"

        flow do
          step("seed",
            action: unquote(EchoParamsAction),
            params: %{
              value: input(:value),
              items: input(:items),
              route: input(:route)
            }
          )

          choice "routed" do
            option "add" do
              action(unquote(Add))
              params(%{value: select(result("seed"), [:value]), amount: 1})
              condition(input(:route) == :add)
            end

            otherwise(
              action: unquote(Multiply),
              params: %{value: select(result("seed"), [:value]), amount: 2}
            )
          end

          map("mapped",
            collection: select(result("seed"), [:items]),
            action: unquote(Add),
            params: %{value: item(), amount: select(result("routed"), [:value])}
          )

          reduce "total" do
            collection(result("mapped"))
            initial(%{value: 0})
            action(unquote(Add))
            params(%{value: accumulator(:value), amount: item(:value)})
          end

          iterate "incremented" do
            state([], initial: %{value: select(result("total"), [:value])})
            action(unquote(Add))
            params(%{value: state(:value), amount: 1})
            repeat(2)
          end

          output(%{
            route: select(result("routed"), [:value]),
            mapped: result("mapped"),
            total: select(result("total"), [:value]),
            final: select(result("incremented"), [:state, :value])
          })
        end
      end
    )

    assert {:ok,
            %{
              route: 3,
              mapped: %{kind: :jido_flow_map_result, errors: []},
              total: 9,
              final: 11
            }} = Jido.Exec.run(module, %{value: 2, items: [1, 2], route: :add}, %{})
  end

  test "short and block Step forms lower to equal nodes" do
    short = unique_module("ShortStepFlow")
    block = unique_module("BlockStepFlow")

    create_module(
      short,
      quote do
        use Jido.Flow, name: "step_form_parity"

        flow do
          step("echo",
            action: unquote(EchoParamsAction),
            params: %{value: input(:value)}
          )
        end
      end
    )

    create_module(
      block,
      quote do
        use Jido.Flow, name: "step_form_parity"

        flow do
          step "echo" do
            action(unquote(EchoParamsAction))
            params(%{value: input(:value)})
          end
        end
      end
    )

    assert Jido.Flow.to_map(short.flow()) == Jido.Flow.to_map(block.flow())
  end

  test "short Choice options capture native conditions as data" do
    module = unique_module("ShortChoiceOptionFlow")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "short_choice_option_flow"

        flow do
          choice "route" do
            option("priority",
              action: unquote(Add),
              params: %{value: input(:value), amount: 1},
              condition: input(:kind) == :priority
            )

            otherwise do
              action(unquote(Multiply))
              params(%{value: input(:value), amount: 2})
            end
          end
        end
      end
    )

    assert {:ok, %{value: 4}} =
             Jido.Exec.run(module, %{kind: :priority, value: 3}, %{})
  end

  test "short forms reject executable expressions without evaluating them" do
    module = unique_module("ExecutableExpressionFlow")

    assert_raise CompileError, ~r/unsupported Flow expression/, fn ->
      create_module(
        module,
        quote do
          use Jido.Flow, name: "executable_expression_flow"

          flow do
            step("echo",
              action: unquote(EchoParamsAction),
              params: send(self(), :flow_expression_was_evaluated)
            )
          end
        end
      )
    end

    refute_received :flow_expression_was_evaluated
  end

  test "lowering errors report the source declaration line" do
    module = unique_module("ExpressionSourceLineFlow")
    file = "expression_source_line_flow.ex"

    source = """
    defmodule #{inspect(module)} do
      use Jido.Flow, name: "expression_source_line_flow"

      flow do
        step("bad",
          action: JidoActionTest.TestActions.EchoParamsAction,
          params: %{value: Date.utc_today()}
        )
      end
    end
    """

    error =
      assert_raise CompileError, ~r/unsupported Flow expression/, fn ->
        Code.compile_string(source, file)
      end

    assert error.file == file
    assert error.line == 7
  end

  test "structural and Action contract errors report the source node line" do
    structural_module =
      Module.concat(
        JidoActionTest,
        "StructuralSourceLineFlow#{System.unique_integer([:positive])}"
      )

    structural_file = "structural_source_line_flow.ex"

    structural_source = """
    defmodule #{inspect(structural_module)} do
      use Jido.Flow, name: "structural_source_line_flow"

      flow do
        choice "empty" do
        end
      end
    end
    """

    structural_error =
      assert_raise CompileError, ~r/choice must declare at least one option/, fn ->
        Code.compile_string(structural_source, structural_file)
      end

    assert structural_error.file == structural_file
    assert structural_error.line == 5

    contract_module =
      Module.concat(JidoActionTest, "ContractSourceLineFlow#{System.unique_integer([:positive])}")

    contract_file = "contract_source_line_flow.ex"

    contract_source = """
    defmodule #{inspect(contract_module)} do
      use Jido.Flow, name: "contract_source_line_flow"

      flow do
        step("bad", action: String, params: %{})
      end
    end
    """

    contract_error =
      assert_raise CompileError, ~r/node: "bad"/, fn ->
        Code.compile_string(contract_source, contract_file)
      end

    assert contract_error.file == contract_file
    assert contract_error.line == 5
  end

  test "short forms reject duplicate declaration fields" do
    module = unique_module("DuplicateStepFieldFlow")

    assert_raise CompileError, ~r/duplicate Flow declaration field: :params/, fn ->
      create_module(
        module,
        quote do
          use Jido.Flow, name: "duplicate_step_field_flow"

          flow do
            step("add",
              action: unquote(Add),
              params: %{value: value(1)},
              params: %{value: value(9)}
            )
          end
        end
      )
    end
  end

  test "Flow declarations reject invalid and mixed option forms" do
    invalid_options = unique_module("InvalidStepOptionsFlow")

    assert_raise CompileError, ~r/Flow declaration options must be a keyword list/, fn ->
      create_module(
        invalid_options,
        quote do
          use Jido.Flow, name: "invalid_step_options_flow"

          flow do
            step("echo", :invalid)
          end
        end
      )
    end

    mixed_step = unique_module("MixedStepOptionsFlow")

    assert_raise CompileError,
                 ~r/do not mix keyword and block fields in one declaration/,
                 fn ->
                   create_module(
                     mixed_step,
                     quote do
                       use Jido.Flow, name: "mixed_step_options_flow"

                       flow do
                         step("echo",
                           action: unquote(EchoParamsAction),
                           do: params(%{value: input(:value)})
                         )
                       end
                     end
                   )
                 end

    missing_block = unique_module("MissingChoiceBlockFlow")

    assert_raise CompileError, ~r/this Flow declaration requires a do block/, fn ->
      create_module(
        missing_block,
        quote do
          use Jido.Flow, name: "missing_choice_block_flow"

          flow do
            choice("route", action: unquote(EchoParamsAction))
          end
        end
      )
    end
  end

  test "Choice targets reject invalid, duplicate, and mixed option forms" do
    invalid_options = unique_module("InvalidChoiceOptionsFlow")

    assert_raise CompileError, ~r/Choice declaration options must be a keyword list/, fn ->
      create_module(
        invalid_options,
        quote do
          use Jido.Flow, name: "invalid_choice_options_flow"

          flow do
            choice "route" do
              option("echo", :invalid)
            end
          end
        end
      )
    end

    duplicate_field = unique_module("DuplicateChoiceFieldFlow")

    assert_raise CompileError, ~r/duplicate Choice declaration field: :params/, fn ->
      create_module(
        duplicate_field,
        quote do
          use Jido.Flow, name: "duplicate_choice_field_flow"

          flow do
            choice "route" do
              option("echo",
                action: unquote(EchoParamsAction),
                condition: value(true),
                params: %{value: value(1)},
                params: %{value: value(2)}
              )
            end
          end
        end
      )
    end

    mixed_target = unique_module("MixedChoiceTargetFlow")

    assert_raise CompileError,
                 ~r/do not mix keyword and block fields in one Choice target/,
                 fn ->
                   create_module(
                     mixed_target,
                     quote do
                       use Jido.Flow, name: "mixed_choice_target_flow"

                       flow do
                         choice "route" do
                           option("echo",
                             action: unquote(EchoParamsAction),
                             do: params(%{value: value(1)})
                           )
                         end
                       end
                     end
                   )
                 end
  end

  test "Iterate state rejects invalid, duplicate, and mixed option forms" do
    invalid_options = unique_module("InvalidIterateStateOptionsFlow")

    assert_raise CompileError, ~r/Iterate state options must be a keyword list/, fn ->
      create_module(
        invalid_options,
        quote do
          use Jido.Flow, name: "invalid_iterate_state_options_flow"

          flow do
            iterate "loop" do
              state([], :invalid)
            end
          end
        end
      )
    end

    duplicate_field = unique_module("DuplicateIterateStateFieldFlow")

    assert_raise CompileError, ~r/duplicate Iterate state field: :initial/, fn ->
      create_module(
        duplicate_field,
        quote do
          use Jido.Flow, name: "duplicate_iterate_state_field_flow"

          flow do
            iterate "loop" do
              state([], initial: %{value: value(1)}, initial: %{value: value(2)})
            end
          end
        end
      )
    end

    mixed_state = unique_module("MixedIterateStateFlow")

    assert_raise CompileError, ~r/do not mix keyword and block fields in Iterate state/, fn ->
      create_module(
        mixed_state,
        quote do
          use Jido.Flow, name: "mixed_iterate_state_flow"

          flow do
            iterate "loop" do
              state([],
                initial: %{value: value(1)},
                do: initial(%{value: value(2)})
              )
            end
          end
        end
      )
    end
  end

  test "lowering rejects incomplete Choice and Iterate declarations" do
    empty_choice = unique_module("EmptyChoiceFlow")

    assert_raise CompileError, ~r/choice must declare at least one option/, fn ->
      create_module(
        empty_choice,
        quote do
          use Jido.Flow, name: "empty_choice_flow"

          flow do
            choice "route" do
            end
          end
        end
      )
    end

    missing_fallback = unique_module("MissingChoiceFallbackFlow")

    assert_raise CompileError, ~r/choice must declare otherwise/, fn ->
      create_module(
        missing_fallback,
        quote do
          use Jido.Flow, name: "missing_choice_fallback_flow"

          flow do
            choice "route" do
              option("echo",
                action: unquote(EchoParamsAction),
                condition: input(:route) == :echo,
                params: %{value: value(1)}
              )
            end
          end
        end
      )
    end

    missing_state = unique_module("MissingIterateStateFlow")

    assert_raise CompileError, ~r/iterate must declare one state/, fn ->
      create_module(
        missing_state,
        quote do
          use Jido.Flow, name: "missing_iterate_state_flow"

          flow do
            iterate "loop" do
              action(unquote(EchoParamsAction))
              params(%{value: value(1)})
              repeat(1)
            end
          end
        end
      )
    end
  end

  test "lowering rejects an output before another declaration" do
    module = unique_module("NonFinalOutputFlow")

    assert_raise CompileError, ~r/output must be the final Flow declaration/, fn ->
      create_module(
        module,
        quote do
          use Jido.Flow, name: "non_final_output_flow"

          flow do
            output(%{value: value(1)})

            step("echo",
              action: unquote(EchoParamsAction),
              params: %{value: value(1)}
            )
          end
        end
      )
    end
  end

  test "short forms reject duplicate literal map keys" do
    module = unique_module("DuplicateLiteralKeyFlow")

    assert_raise CompileError, ~r/duplicate Flow map key: :value/, fn ->
      create_module(
        module,
        quote do
          use Jido.Flow, name: "duplicate_literal_key_flow"

          flow do
            step("add",
              action: unquote(Add),
              params: %{value: value(1), value: value(9)}
            )
          end
        end
      )
    end
  end

  test "executes bounded Iterate while with an explicit state adapter" do
    module = unique_module("WhileIterateFlow")

    create_module(
      module,
      quote do
        use Jido.Flow, name: "while_iterate_flow"

        flow do
          iterate "count" do
            state([], initial: %{count: input(:start)})
            action(unquote(Add))
            params(%{value: state(:count), amount: 1})
            update(%{count: body_result(:value)})
            while(state(:count) < 3)
            max_iterations(5)
          end

          output(%{count: select(result("count"), [:state, :count])})
        end
      end
    )

    assert {:ok, %{count: 3}} = Jido.Exec.run(module, %{start: 1}, %{})
  end

  test "short and block Map and Reduce forms lower to equal nodes" do
    short = unique_module("ShortCollectionFlow")
    block = unique_module("BlockCollectionFlow")

    create_module(
      short,
      quote do
        use Jido.Flow, name: "collection_form_parity"

        flow do
          map("mapped",
            collection: input(:items),
            action: unquote(Multiply),
            params: %{value: item(:value), amount: 2}
          )

          reduce("total",
            collection: result("mapped"),
            initial: %{value: 0},
            action: unquote(Add),
            params: %{value: accumulator(:value), amount: item(:value)}
          )
        end
      end
    )

    create_module(
      block,
      quote do
        use Jido.Flow, name: "collection_form_parity"

        flow do
          map "mapped" do
            collection(input(:items))
            action(unquote(Multiply))
            params(%{value: item(:value), amount: 2})
          end

          reduce "total" do
            collection(result("mapped"))
            initial(%{value: 0})
            action(unquote(Add))
            params(%{value: accumulator(:value), amount: item(:value)})
          end
        end
      end
    )

    assert Jido.Flow.to_map(short.flow()) == Jido.Flow.to_map(block.flow())
  end
end
