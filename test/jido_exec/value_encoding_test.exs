defmodule Jido.Exec.ValueEncodingTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias Runic.Runner
  alias JidoActionTest.Fixtures.LocalItems

  defmodule Echo do
    use Jido.Action, name: "encoding_echo"
    @impl true
    def run(params, _), do: {:ok, params}
  end

  defmodule FromContext do
    use Jido.Action, name: "encoding_from_context"
    @impl true
    def run(_, %{value: value}), do: {:ok, %{value: value}, [:produced]}
  end

  defmodule Child do
    use Jido.Flow, name: "encoding_child"

    flow do
      step "echo", action: Echo, params: %{}
      output %{value: input(:value)}
    end
  end

  defmodule Envelope do
    use Jido.Action, name: "encoding_envelope"
    @impl true
    def run(%{kind: kind, value: value}, _), do: {:ok, apply(Output, kind, [value]), [:produced]}
  end

  defmodule LocalEnvelope do
    use Jido.Action, name: "encoding_local_envelope"
    @impl true
    def run(_, _), do: {:ok, Output.opaque(make_ref())}
  end

  defmodule OutputValidator do
    @behaviour Jido.Flow
    @impl true
    def flow do
      Jido.Flow.new!(%{
        name: "encoding_output_validator",
        components: [
          %{kind: :step, name: "echo", action: Echo, params: %{}}
        ],
        output: Ref.result("echo")
      })
    end

    @impl true
    def validate_params(params), do: {:ok, params}
    @impl true
    def validate_output(output), do: {:ok, Map.put(output, :validator_ref, make_ref())}
    def run(params, context), do: Exec.run(__MODULE__, params, context)
  end

  defmodule InputValidator do
    @behaviour Jido.Flow
    @impl true
    def flow, do: OutputValidator.flow()
    @impl true
    def validate_params(params), do: {:ok, Map.put(params, :validator_ref, make_ref())}
    @impl true
    def validate_output(output), do: {:ok, output}
    def run(params, context), do: Exec.run(__MODULE__, params, context)
  end

  def local_state(value, _opts), do: {:ok, Map.put(value, :validator_ref, make_ref())}

  setup do
    runner = :"encoding_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for boundary <- [:action, :output, :nested_input] do
    test "immediate #{boundary} retains local mode after native joins" do
      value = make_ref()
      flow = joined_flow(unquote(boundary))

      expected =
        if unquote(boundary) == :action,
          do: {:ok, %{value: value}, [:produced]},
          else: {:ok, %{value: value}}

      assert Exec.run(flow, %{}, %{value: value}) == expected
    end
  end

  test "managed envelopes preserve public values and accepted replay", %{runner: runner} do
    for {kind, value} <- [raw: "text", batch: [1, 2], opaque: "text"] do
      expected = apply(Output, kind, [value])
      id = {:envelope, kind}
      completed = managed(runner, id, Envelope, %{kind: kind, value: value})
      assert Exec.result(completed) == {:ok, expected, [:produced]}
      assert :ok = Runner.checkpoint(runner, id)
      assert :ok = Runner.stop(runner, id, persist: true)
      {:ok, _} = Exec.resume(runner, id)
      {:ok, restored} = Runner.get_workflow(runner, id)
      assert Exec.result(restored) == {:ok, expected, [:produced]}
    end
  end

  test "accepted portable input and output terms survive managed execution", %{runner: runner} do
    for {label, value} <- [
          uri: URI.parse("https://example.com"),
          improper: [1 | :tail],
          bits: <<1::1>>
        ] do
      completed = managed(runner, {:value, label}, Echo, %{value: value})
      assert Exec.result(completed) == {:ok, %{value: value}}

      flow =
        Jido.Flow.new!(%{
          name: "portable_input_#{label}",
          components: [
            %{kind: :step, name: "echo", action: Echo, params: %{value: Ref.input(:value)}}
          ],
          output: Ref.result("echo")
        })

      assert Exec.result(managed(runner, {:flow_value, label}, flow, %{value: value})) ==
               {:ok, %{value: value}}
    end
  end

  test "portable encoding still rejects process-local envelope contents", %{runner: runner} do
    completed = managed(runner, :rejected, LocalEnvelope, %{})

    assert {:error, %{details: %{reason: :non_portable_durable_value, type: :reference}}} =
             Exec.result(completed)

    assert {:error, %{details: %{reason: :non_portable_durable_value}}} =
             Exec.start(runner, :local_input, Envelope, %{kind: :opaque, value: make_ref()})
  end

  test "whole context expressions expose only caller context", %{runner: runner} do
    flow =
      Jido.Flow.new!(%{
        name: "encoding_public_context",
        components: [
          %{kind: :step, name: "echo", action: Echo, params: %{}}
        ],
        output: Ref.context()
      })

    context = %{user: "caller"}
    assert Exec.run(flow, %{}, context) == {:ok, context}
    assert Exec.result(managed(runner, :context, flow, %{}, context)) == {:ok, context}
  end

  test "validator process-local outputs are known failures, not uncertain work", %{runner: runner} do
    nested_input =
      Jido.Flow.new!(%{
        name: "encoding_nested_input_validator",
        components: [
          %{kind: :subflow, name: "child", flow: InputValidator}
        ],
        output: Ref.result("child")
      })

    nested_output =
      Jido.Flow.new!(%{
        name: "encoding_nested_output_validator",
        components: [
          %{kind: :subflow, name: "child", flow: OutputValidator}
        ],
        output: Ref.result("child")
      })

    for {id, target} <- [
          root_output: OutputValidator,
          nested_input: nested_input,
          nested_output: nested_output
        ] do
      completed = managed(runner, id, target, %{})

      assert {:error,
              %{
                details: %{
                  phase: :durability,
                  reason: :non_portable_durable_value,
                  type: :reference
                }
              }} = Exec.result(completed)

      assert Enum.any?(completed.runnable_events, &is_struct(&1, Runic.Workflow.RunnableFailed))

      refute Enum.any?(
               completed.runnable_events,
               &is_struct(&1, Runic.Workflow.ExecutionUncertain)
             )
    end
  end

  for kind <- [:map, :reduce, :iterate] do
    test "#{kind} expansion rejects local data as a known failure", %{runner: runner} do
      kind = unquote(kind)
      completed = managed(runner, kind, expansion_flow(kind), %{items: %LocalItems{}})

      assert {:error,
              %{
                details: %{
                  phase: :durability,
                  reason: :non_portable_durable_value,
                  type: :reference
                }
              }} = Exec.result(completed)

      assert Enum.any?(completed.runnable_events, &is_struct(&1, Runic.Workflow.RunnableFailed))

      refute Enum.any?(
               completed.runnable_events,
               &is_struct(&1, Runic.Workflow.ExecutionUncertain)
             )
    end
  end

  defp expansion_flow(kind) do
    schema = Zoi.map(%{}) |> Zoi.transform({__MODULE__, :local_state, []})

    component =
      case kind do
        :map ->
          %{
            kind: :map,
            name: "items",
            collection: Ref.input(:items),
            action: Echo,
            params: %{value: Ref.item()}
          }

        :reduce ->
          %{
            kind: :reduce,
            name: "items",
            collection: Ref.input(:items),
            initial: %{},
            action: Echo,
            params: %{value: Ref.item()}
          }

        :iterate ->
          %{
            kind: :iterate,
            name: "items",
            action: Echo,
            params: %{},
            state: %{schema: schema, initial: %{}, update: %{}},
            completion: true,
            max_iterations: 1
          }
      end

    Jido.Flow.new!(%{
      name: "encoding_expansion_#{kind}",
      components: [component],
      output: Ref.result("items")
    })
  end

  defp managed(runner, id, target, params, context \\ %{}) do
    owner = self()

    {:ok, _} =
      Exec.start(runner, id, target, params, context,
        on_complete: fn _, workflow -> send(owner, {:done, id, workflow}) end
      )

    assert_receive {:done, ^id, workflow}, 2_000
    workflow
  end

  defp joined_flow(boundary) do
    parents = [
      %{kind: :step, name: "a", action: Echo, params: %{a: 1}},
      %{kind: :step, name: "b", action: Echo, params: %{b: 2}}
    ]

    {tail, output} =
      case boundary do
        :action ->
          {[%{kind: :step, name: "value", action: FromContext, needs: ["a", "b"]}],
           Ref.result("value")}

        :output ->
          {[], %{value: Ref.context(:value)}}

        :nested_input ->
          {[
             %{
               kind: :subflow,
               name: "child",
               flow: Child,
               needs: ["a", "b"],
               params: %{value: Ref.context(:value)}
             }
           ], Ref.result("child")}
      end

    Jido.Flow.new!(%{
      name: "joined_encoding_#{boundary}",
      components: parents ++ tail,
      output: output
    })
  end
end
