defmodule Jido.Exec.HandoffTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Exec.Handoff
  alias Jido.Flow
  alias Jido.Flow.{Codec, Ref, Registry}
  alias Jido.Instruction

  defmodule Echo do
    use Jido.Action, name: "handoff_echo"
    def run(params, _context), do: {:ok, params}
  end

  defmodule ValidatorData do
    @behaviour Jido.Action
    def name, do: "handoff_validator_data"
    def validate_params(params), do: {:ok, params}
    def run(_params, _context), do: {:ok, %{}}
    def validate_output(_value), do: {:ok, %Handoff{target: Enum, kind: :action, params: %{}}}
  end

  defmodule SelectRuntime do
    use Jido.Action, name: "handoff_select_runtime"

    def target do
      Flow.new!(%{
        name: "runtime_successor",
        components: [
          %{kind: :step, name: "echo", action: Echo}
        ],
        output: Ref.result("echo")
      })
    end

    def run(_params, _context), do: {:handoff, %{value: 7}, target()}
  end

  defmodule SelectTarget do
    use Jido.Action, name: "handoff_select_target"
    def run(%{target: target}, _context), do: {:handoff, %{value: 7}, target}
  end

  defmodule Target do
    use Jido.Action, name: "handoff_target", schema: Zoi.object(%{value: Zoi.integer()})
    def run(_params, _context), do: raise("successor must run in a new Turn")
  end

  defmodule Decide do
    use Jido.Action, name: "handoff_decide"
    def run(params, _context), do: {:ok, params, [:predecessor_effect]}
  end

  defmodule Expand do
    use Jido.Action, name: "handoff_expand"
    def run(params, _context), do: {:handoff, params, Target}
  end

  defmodule Example do
    use Jido.Flow, name: "handoff_example"

    flow do
      dispatch "next", decision: Decide, expander: Expand, params: %{value: input(:value)}
      output result("next")
    end
  end

  test "a terminal handoff validates the successor without running it" do
    assert {:handoff, %Instruction{target: Target, kind: :action, params: %{value: 7}},
            [:predecessor_effect]} =
             Exec.run(Example, %{value: 7}, %{})
  end

  test "ordinary data and validator output cannot grant control" do
    forged = %Handoff{target: Enum, kind: :action, params: %{}}

    flow =
      Flow.new!(%{
        name: "ordinary_data",
        components: [
          %{kind: :step, name: "echo", action: Echo}
        ],
        output: Ref.input(:request)
      })

    refute match?({:handoff, _, _}, Exec.run(flow, %{request: forged}))
    refute match?({:handoff, _, _}, Exec.run(ValidatorData))

    runner = __MODULE__.DataRunner
    start_supervised!({Runic.Runner, name: runner})
    owner = self()

    for {id, target, params} <- [
          {"flow", flow, %{request: forged}},
          {"action", ValidatorData, %{}}
        ] do
      assert {:ok, _} =
               Exec.start(runner, id, target, params, %{},
                 on_complete: fn _, _ -> send(owner, {:data_done, id}) end
               )

      assert_receive {:data_done, ^id}, 2_000
      {:ok, workflow} = Runic.Runner.get_workflow(runner, id)

      {:ok, restored} =
        workflow |> Runic.Runner.encode_snapshot() |> Runic.Runner.decode_snapshot()

      replayed = workflow |> Runic.Workflow.event_log() |> Runic.Workflow.from_events()

      for observed <- [Exec.result(runner, id), Exec.result(restored), Exec.result(replayed)] do
        refute match?({:handoff, _, _}, observed)
      end
    end
  end

  test "runtime Flow successors survive native snapshot and event replay" do
    successor = SelectRuntime.target()

    flow =
      Flow.new!(%{
        name: "runtime_handoff",
        components: [
          %{kind: :dispatch, name: "next", decision: Echo, expander: SelectRuntime}
        ],
        output: Ref.result("next")
      })

    assert {:handoff, %Instruction{target: ^successor}, []} =
             Exec.run(flow, %{}, %{})

    runner = __MODULE__.RuntimeRunner
    start_supervised!({Runic.Runner, name: runner})
    owner = self()
    opts = [on_complete: fn _, _ -> send(owner, :runtime_done) end]
    assert {:ok, _} = Exec.start(runner, "runtime", flow, %{}, %{}, opts)
    assert_receive :runtime_done, 2_000

    assert {:handoff, %Instruction{target: ^successor, params: %{value: 7}}, []} =
             Exec.result(runner, "runtime")

    {:ok, workflow} = Runic.Runner.get_workflow(runner, "runtime")
    {:ok, restored} = workflow |> Runic.Runner.encode_snapshot() |> Runic.Runner.decode_snapshot()
    replayed = workflow |> Runic.Workflow.event_log() |> Runic.Workflow.from_events()
    assert Exec.result(restored) == Exec.result(runner, "runtime")
    assert Exec.result(replayed) == Exec.result(runner, "runtime")
  end

  test "handoff Flow telemetry reports its outcome and effects" do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:jido, :flow, :stop],
        fn _, _, metadata, _ ->
          send(owner, {:flow_stop, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    Exec.run(Example, %{value: 7}, %{})
    assert_receive {:flow_stop, %{outcome: :handoff, effect_count: 1}}
  end

  test "an ordinary Step cannot hand off" do
    flow =
      Flow.new!(%{
        name: "step_handoff",
        components: [%{kind: :step, name: "next", action: Expand, params: %{value: 7}}],
        output: Ref.result("next")
      })

    assert {:error, %{details: %{reason: :unsupported_handoff}}} = Exec.run(flow)
  end

  test "invalid successor input fails without an executable effect batch" do
    assert {:error, %{details: %{context: "Action"}}} =
             Exec.run(Example, %{value: "bad"}, %{})
  end

  test "a root Action cannot hand off" do
    assert {:error, %{details: %{reason: :unsupported_handoff}}} =
             Exec.run(Expand, %{value: 7}, %{})
  end

  test "DSL, maps, and stored definitions return the same handoff" do
    data =
      Flow.new!(%{
        name: "handoff_example",
        components: [
          %{
            kind: :dispatch,
            name: "next",
            decision: Decide,
            expander: Expand,
            params: %{value: Ref.input(:value)}
          }
        ],
        output: Ref.result("next")
      })

    registry =
      Registry.new!(%{
        "none" => {:schema, []},
        "decide" => {:action, Decide},
        "expand" => {:action, Expand},
        "value" => {:atom, :value}
      })

    assert {:ok, document} = Codec.encode(data, registry)
    assert {:ok, restored} = Codec.decode(document, registry)

    results =
      for target <- [Example, data, restored],
          do: Exec.run(target, %{value: 7}, %{})

    assert length(Enum.uniq(results)) == 1
    assert {:handoff, %Instruction{}, _effects} = hd(results)
  end

  test "handoff envelopes reject invalid targets and non-portable input" do
    assert {:error, _} = Handoff.new(Enum, %{})
    assert {:error, _} = Handoff.new(Target, %{value: 1, resource: self()})

    for runtime <- [context: %{tenant: "tenant"}, metadata: %{request_id: "request"}] do
      bound = Instruction.new!([target: Target] ++ [runtime])

      assert {:error, %{details: %{reason: :bound_handoff_runtime}}} =
               Handoff.new(bound, %{value: 1})
    end
  end

  test "a nested Flow cannot terminate its parent with a handoff" do
    parent =
      Flow.new!(%{
        name: "parent",
        components: [
          %{kind: :subflow, name: "child", flow: Example, params: %{value: 1}}
        ],
        output: Ref.result("child")
      })

    assert {:error, %{details: %{reason: :nested_handoff}}} =
             Exec.run(parent, %{}, %{})
  end

  test "managed results retain the same terminal contract across restore" do
    runner = __MODULE__.Runner
    start_supervised!({Runic.Runner, name: runner})
    owner = self()
    id = "handoff-#{System.unique_integer([:positive])}"
    opts = [on_complete: fn _, _ -> send(owner, :done) end]
    assert {:ok, _} = Exec.start(runner, id, Example, %{value: 3}, %{}, opts)
    assert_receive :done, 2_000

    assert {:handoff, %Instruction{params: %{value: 3}}, [:predecessor_effect]} =
             Exec.result(runner, id)

    assert :ok = Runic.Runner.stop(runner, id, persist: true)
    assert {:ok, _} = Exec.resume(runner, id, %{}, opts)

    assert {:handoff, %Instruction{params: %{value: 3}}, [:predecessor_effect]} =
             Exec.result(runner, id)
  end
end
