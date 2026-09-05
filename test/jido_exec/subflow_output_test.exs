defmodule JidoActionTest.Exec.SubflowOutputTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Builder, Codec, Ref, Step, Subflow}
  alias JidoActionTest.Fixtures.Actions.EchoParamsAction

  defmodule Child do
    use Jido.Flow, name: "context_output_child"

    flow do
      step "work", action: EchoParamsAction, params: %{value: input(:value)}
      output %{work: result("work"), tenant: context(:tenant)}
    end
  end

  defmodule Parent do
    use Jido.Flow, name: "context_output_parent"

    flow do
      step "child", action: Child, params: %{value: input(:value)}
      output result("child")
    end
  end

  defmodule ExpressionChild do
    use Jido.Flow, name: "expression_output_child"

    flow do
      step "work", action: EchoParamsAction, params: %{value: input(:value) + 1}
      step "other", action: EchoParamsAction, params: %{value: input(:value) * 2}

      output %{
        input: input(:value),
        work: result("work"),
        context: context(),
        nested: %{
          values: [
            context([:accounts, 0, :tenant]),
            context(:prefix) <> input(:label) <> context(:suffix)
          ],
          total: result("work", :value) + result("other", :value) + context(:adjustment)
        }
      }
    end
  end

  defmodule Nested do
    use Jido.Flow, name: "nested_context_output"

    flow do
      step "work", action: EchoParamsAction, params: %{value: input(:value) + 100}

      step "child",
        action: ExpressionChild,
        params: %{value: input(:value) + 1, label: input(:label)}

      output %{
        input: input(:value),
        work: result("work"),
        child: result("child"),
        tenant: context([:accounts, 0, :tenant])
      }
    end
  end

  defmodule NoResultChild do
    use Jido.Flow, name: "no_result_context_output"

    flow do
      step "work", action: EchoParamsAction, params: %{}

      output %{
        input: input(:value),
        tenant: context([:account, :tenant]),
        nil?: context([:account, :tenant]) == nil
      }
    end
  end

  defmodule ContextOutput do
    use Jido.Flow, name: "complete_context_output"

    flow do
      step "work", action: EchoParamsAction, params: %{}
      output context(:output)
    end
  end

  test "root and child outputs use the same caller context" do
    parent =
      Flow.new!(
        name: "context_output_parent",
        components: [
          Subflow.new!(name: "child", flow: Child, params: %{value: Ref.input(:value)})
        ],
        output: Ref.result("child")
      )

    expected = {:ok, %{work: %{value: 7}, tenant: "acme"}}
    assert Exec.run(Child, %{value: 7}, %{tenant: "acme"}) == expected
    assert Exec.run(parent, %{value: 7}, %{tenant: "acme"}) == expected
  end

  test "all authoring forms preserve root and child output context" do
    child =
      Flow.new!(
        name: "context_output_child",
        components: [
          Step.new!(name: "work", action: EchoParamsAction, params: %{value: Ref.input(:value)})
        ],
        output: %{work: Ref.result("work"), tenant: Ref.context(:tenant)}
      )

    {:ok, built_child} =
      Builder.new(name: child.name)
      |> Builder.step("work", EchoParamsAction, %{value: Ref.input(:value)})
      |> Builder.output(child.output)
      |> Builder.build()

    parent = parent_flow(Child)

    {:ok, built_parent} =
      Builder.new(name: parent.name)
      |> Builder.step("child", Child, %{value: Ref.input(:value)})
      |> Builder.output(parent.output)
      |> Builder.build()

    assert child == Child.flow()
    assert child == built_child
    assert parent == Parent.flow()
    assert parent == built_parent

    for flow <- [
          Child,
          child,
          built_child,
          from_json(child),
          Parent,
          parent,
          built_parent,
          from_json(parent)
        ] do
      assert Exec.run(flow, %{value: 7}, %{tenant: "acme"}) ==
               {:ok, %{work: %{value: 7}, tenant: "acme"}}
    end
  end

  test "nested expressions keep local input and results with the full caller context" do
    context = expression_context()
    input = %{value: 7, label: "child"}
    parent = parent_flow(ExpressionChild, Ref.input([]))
    expected = {:ok, expression_output(7, "child", context)}

    for flow <- [ExpressionChild, parent, from_json(parent)],
        mode <- [:run, :step, :wave, :continue] do
      assert execute(flow, input, context, mode) == expected
    end
  end

  test "two child levels and repeated calls keep each input and result scope" do
    parent =
      Flow.new!(
        name: "repeated_nested_context_output",
        components: [
          Step.new!(name: "work", action: EchoParamsAction, params: %{value: 999}),
          Subflow.new!(
            name: "left",
            flow: Nested,
            params: %{value: Ref.input(:left), label: "left"}
          ),
          Subflow.new!(
            name: "right",
            flow: Nested,
            params: %{value: Ref.input(:right), label: "right"}
          )
        ],
        output: %{
          input: Ref.input(:value),
          work: Ref.result("work"),
          left: Ref.result("left"),
          right: Ref.result("right")
        }
      )

    context = expression_context()

    expected =
      {:ok,
       %{
         input: 500,
         work: %{value: 999},
         left: %{
           input: 2,
           work: %{value: 102},
           child: expression_output(3, "left", context),
           tenant: "acme"
         },
         right: %{
           input: 8,
           work: %{value: 108},
           child: expression_output(9, "right", context),
           tenant: "acme"
         }
       }}

    for mode <- [:run, :step, :wave, :continue] do
      assert execute(parent, %{value: 500, left: 2, right: 8}, context, mode) == expected
    end
  end

  test "output without result references uses child input and preserves present nil" do
    for tenant <- ["acme", nil],
        flow <- [NoResultChild, parent_flow(NoResultChild)],
        mode <- [:run, :step, :wave, :continue] do
      assert execute(flow, %{value: 7}, %{account: %{tenant: tenant}}, mode) ==
               {:ok, %{input: 7, tenant: tenant, nil?: is_nil(tenant)}}
    end

    assert Exec.run(Child, %{value: 7}, %{tenant: nil}) ==
             {:ok, %{work: %{value: 7}, tenant: nil}}

    assert Exec.run(Parent, %{value: 7}, %{tenant: nil}) ==
             {:ok, %{work: %{value: 7}, tenant: nil}}
  end

  test "context can select a complete map or list output envelope" do
    values = [%{value: 7}, nil]

    for output <- [
          %{items: values},
          Output.batch(values, meta: %{source: "context"}),
          Output.batch([])
        ],
        flow <- [ContextOutput, parent_flow(ContextOutput)],
        mode <- [:run, :step, :wave, :continue] do
      assert execute(flow, %{value: 7}, %{output: output}, mode) == {:ok, output}
    end
  end

  test "a bare list from context still requires an output envelope" do
    for {flow, message} <- [
          {ContextOutput, "Flow returned a value that requires an output envelope"},
          {parent_flow(ContextOutput), "Action output validation must return a map"}
        ],
        output <- [[], [%{value: 7}]],
        mode <- [:run, :step, :wave, :continue] do
      assert {:error, error} = execute(flow, %{value: 7}, %{output: output}, mode)
      assert Exception.message(error) == message
    end
  end

  test "missing context keys remain structured errors in root and child outputs" do
    for flow <- [Child, Parent], mode <- [:run, :step, :wave, :continue] do
      assert {:error, %Jido.Flow.Error.ExecutionFailureError{} = error} =
               execute(flow, %{value: 7}, %{}, mode)

      assert error.message == "flow reference path does not exist"
      assert error.details.ref_type == :context
      assert error.details.reason == :missing_key
      assert error.details.path == [:tenant]
      assert error.details.retry == false
    end
  end

  test "missing context inside an expression keeps the same reference error" do
    context = Map.delete(expression_context(), :suffix)

    for flow <- [ExpressionChild, parent_flow(ExpressionChild, Ref.input([]))],
        mode <- [:run, :step, :wave, :continue] do
      assert {:error, %Jido.Flow.Error.ExecutionFailureError{} = error} =
               execute(flow, %{value: 7, label: "child"}, context, mode)

      assert error.details.ref_type == :context
      assert error.details.reason == :missing_key
      assert error.details.path == [:suffix]
      assert error.details.expression_path == [:nested, :values, 1, :operands, 1, :operands, 1]
      assert error.details.retry == false
    end
  end

  defp parent_flow(child, params \\ %{value: Ref.input(:value)}) do
    Flow.new!(
      name: "context_output_parent",
      components: [Subflow.new!(name: "child", flow: child, params: params)],
      output: Ref.result("child")
    )
  end

  defp from_json(flow) do
    {:ok, document, registry} = Codec.encode(flow)
    {:ok, restored} = Codec.decode(JSON.decode!(JSON.encode!(document)), registry)
    restored
  end

  defp expression_context do
    %{
      accounts: [%{tenant: "acme"}],
      prefix: "<",
      suffix: ">",
      adjustment: 10,
      token: make_ref()
    }
  end

  defp expression_output(value, label, context) do
    %{
      input: value,
      work: %{value: value + 1},
      context: context,
      nested: %{values: ["acme", "<#{label}>"], total: value * 3 + 11}
    }
  end

  defp execute(flow, input, context, :run), do: Exec.run(flow, input, context)

  defp execute(flow, input, context, mode) do
    {:ok, execution} = Exec.start(flow, input, context)
    finish(execution, mode)
  end

  defp finish(execution, mode) do
    if Exec.status(execution) in [:succeeded, :failed] do
      Exec.result(execution)
    else
      execution =
        case mode do
          :step ->
            {:ok, _runnable, next} = Exec.step(execution)
            next

          :wave ->
            {:ok, _runnables, next} = Exec.wave(execution)
            next

          :continue ->
            {:ok, next} = Exec.continue(execution)
            next
        end

      finish(execution, mode)
    end
  end
end
