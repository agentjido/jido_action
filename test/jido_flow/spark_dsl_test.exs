defmodule Jido.Flow.SparkDSLTest do
  use JidoTest.ActionCase, async: true

  alias JidoTest.TestActions.{Add, EchoParamsAction, Multiply}

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
