defmodule Jido.Exec.HandoffTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Jido.Exec
  alias Jido.Exec.Handoff
  alias Jido.Flow
  alias Jido.Flow.{Codec, Ref, Registry}

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
    assert {:handoff, %Handoff{target: Target, kind: :action, params: %{value: 7}},
            [:predecessor_effect]} =
             Exec.run(Example, %{value: 7}, %{}, host_capabilities: [:handoff])
  end

  test "hosts must explicitly accept handoffs" do
    assert {:error, %{details: %{reason: :unsupported_host, capability: :handoff}}} =
             Exec.run(Example, %{value: 7})
  end

  test "invalid successor input fails without an executable effect batch" do
    assert {:error, %{details: %{context: "Action"}}} =
             Exec.run(Example, %{value: "bad"}, %{}, host_capabilities: [:handoff])
  end

  test "a root Action cannot hand off" do
    assert {:error, %{details: %{reason: :unsupported_handoff}}} =
             Exec.run(Expand, %{value: 7}, %{}, host_capabilities: [:handoff])
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
          do: Exec.run(target, %{value: 7}, %{}, host_capabilities: [:handoff])

    assert length(Enum.uniq(results)) == 1
    assert {:handoff, %Handoff{}, _effects} = hd(results)
  end

  test "handoff envelopes reject invalid targets and non-portable input" do
    assert {:error, _} = Handoff.new(Enum, %{})
    assert {:error, _} = Handoff.new(Target, %{value: 1, resource: self()})
    assert {:error, _} = Handoff.new(Target, %{value: 1}, [:invalid])
    assert {:error, _} = Handoff.new(Target, %{value: 1}, [:handoff | :invalid])
  end

  test "host options reject invalid capability lists" do
    for capabilities <- [nil, [:unknown], [:handoff | :invalid]] do
      assert {:error, %{class: :config}} =
               Exec.run(Example, %{value: 1}, %{}, host_capabilities: capabilities)
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
             Exec.run(parent, %{}, %{}, host_capabilities: [:handoff])
  end

  test "managed results retain the same terminal contract across restore" do
    runner = __MODULE__.Runner
    start_supervised!({Runic.Runner, name: runner})
    owner = self()
    id = "handoff-#{System.unique_integer([:positive])}"
    opts = [host_capabilities: [:handoff], on_complete: fn _, _ -> send(owner, :done) end]
    assert {:ok, _} = Exec.start(runner, id, Example, %{value: 3}, %{}, opts)
    assert_receive :done, 2_000

    assert {:handoff, %Handoff{params: %{value: 3}}, [:predecessor_effect]} =
             Exec.result(runner, id)

    assert :ok = Runic.Runner.stop(runner, id, persist: true)
    assert {:ok, _} = Exec.resume(runner, id, %{}, opts)

    assert {:handoff, %Handoff{params: %{value: 3}}, [:predecessor_effect]} =
             Exec.result(runner, id)
  end
end
