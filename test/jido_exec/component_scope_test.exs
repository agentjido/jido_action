defmodule JidoActionTest.Exec.ComponentScopeTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Flow.Ref
  alias JidoActionTest.Fixtures.Actions.{Add, EchoParamsAction}
  alias JidoActionTest.Fixtures.MathFlow

  defmodule ChildCollections do
    use Jido.Flow, name: "scope_child_collections"

    flow do
      map "m",
        collection: [1, 2],
        action: JidoActionTest.Fixtures.Actions.Add,
        params: %{value: item(), amount: 1}

      reduce "r" do
        collection([1, 2])
        initial(%{value: 0})
        action(JidoActionTest.Fixtures.Actions.Add)
        params(%{value: accumulator(:value), amount: item()})
      end

      iterate "i" do
        state(Zoi.object(%{value: Zoi.integer()}), initial: %{value: 0})
        action(JidoActionTest.Fixtures.Actions.Add)
        params(%{value: state(:value), amount: 1})
        update(%{value: body_result(:value)})
        repeat(2)
      end

      output(%{map: result("m"), reduce: result("r"), iterate: result("i")})
    end
  end

  describe "authored names" do
    test "a name with a path separator stays distinct from a Subflow child" do
      flow =
        Flow.new!(%{
          name: "scope_separator",
          components: [
            %{kind: :step, name: "b/double", action: Add, params: %{value: 1000, amount: 1}},
            %{
              kind: :subflow,
              name: "b",
              flow: MathFlow,
              params: %{value: 1},
              needs: ["b/double"]
            }
          ],
          output: %{top: Ref.result("b/double"), sub: Ref.result("b")}
        })

      assert {:ok, %{top: %{value: 1001}, sub: %{value: 4}}} = Exec.run(flow, %{}, %{})
    end

    test "a name that matches a support node stays distinct from that node" do
      for name <- ["$m/map-input", "$m/map", "$m/map-collector", "$m/map/item"] do
        flow =
          Flow.new!(%{
            name: "scope_support",
            components: [
              %{kind: :step, name: name, action: Add, params: %{value: 1000, amount: 1}},
              %{
                kind: :map,
                name: "m",
                collection: [1, 2],
                action: Add,
                params: %{value: Ref.item(), amount: 1},
                needs: [name]
              }
            ],
            output: %{top: Ref.result(name), items: Ref.result("m")}
          })

        assert {:ok, %{top: %{value: 1001}, items: [%{value: 2}, %{value: 3}]}} =
                 Exec.run(flow, %{}, %{}),
               "collision for #{inspect(name)}"
      end
    end

    test "Subflow child input and output nodes stay distinct from authored names" do
      for name <- ["b/$input", "b/$output"] do
        flow =
          Flow.new!(%{
            name: "scope_boundary",
            components: [
              %{kind: :step, name: name, action: Add, params: %{value: 1000, amount: 1}},
              %{kind: :subflow, name: "b", flow: MathFlow, params: %{value: 1}, needs: [name]}
            ],
            output: %{top: Ref.result(name), sub: Ref.result("b")}
          })

        assert {:ok, %{top: %{value: 1001}, sub: %{value: 4}}} = Exec.run(flow, %{}, %{}),
               "collision for #{inspect(name)}"
      end
    end
  end

  describe "collection identities" do
    @collection_events [
      [:jido, :flow, :map, :item, :start],
      [:jido, :flow, :reduce, :item, :start],
      [:jido, :flow, :iterate, :iteration, :start]
    ]

    test "item and iteration IDs include the Subflow path" do
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach_many(
          handler,
          @collection_events,
          &__MODULE__.record_collection_id/4,
          {self(), "scope_ids"}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      flow =
        Flow.new!(%{
          name: "scope_ids",
          components: [
            %{kind: :subflow, name: "b1", flow: ChildCollections, params: %{}},
            %{kind: :subflow, name: "b2", flow: ChildCollections, params: %{}},
            %{
              kind: :map,
              name: "m",
              collection: [1, 2],
              action: Add,
              params: %{value: Ref.item(), amount: 1}
            }
          ],
          output: %{b1: Ref.result("b1"), b2: Ref.result("b2"), m: Ref.result("m")}
        })

      assert {:ok, _result} = Exec.run(flow, %{}, %{})

      ids = collected_ids([])
      assert length(ids) == 14
      assert length(Enum.uniq(ids)) == 14
    end

    test "a root collection keeps its item ID" do
      flow =
        Flow.new!(%{
          name: "scope_root_ids",
          components: [
            %{
              kind: :map,
              name: "m",
              collection: [1],
              action: EchoParamsAction,
              params: %{id: Ref.item_id()}
            }
          ],
          output: %{items: Ref.result("m")}
        })

      assert {:ok, %{items: [%{id: id}]}} = Exec.run(flow, %{}, %{})
      {:ok, compiled} = Flow.compile(flow)
      assert id == Jido.Flow.Identity.item_uuid(compiled.semantic_digest, ["m"], 0)
    end
  end

  @doc false
  def record_collection_id(_event, _measurements, %{flow: flow} = metadata, {owner, flow}) do
    send(owner, {:collection_id, Map.get(metadata, :item_id) || metadata.iteration_id})
  end

  def record_collection_id(_event, _measurements, _metadata, _config), do: :ok

  defp collected_ids(ids) do
    receive do
      {:collection_id, id} -> collected_ids([id | ids])
    after
      0 -> ids
    end
  end
end
