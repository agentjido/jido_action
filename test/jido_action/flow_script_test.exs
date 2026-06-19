defmodule JidoTest.FlowScriptTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Script
  alias JidoTest.TestActions.{Add, Double, FlowFunctions}

  @script_atoms [
    :scripted_math,
    :scripted_primitives,
    :scripted_projection,
    :scripted_loop,
    :scripted_if,
    :scripted_surface,
    :scripted_round_trip,
    :scripted_switch,
    :scripted_fanout,
    :bad,
    :add,
    :add_one,
    :add_two,
    :cart_id,
    :checkout,
    :collect_payload,
    :dashboard,
    :double,
    :double_each,
    :enterprise,
    :enterprise?,
    :format,
    :format_receipt,
    :load_items,
    :load_order,
    :load_profile,
    :load_settings,
    :load_user,
    :loaded_items,
    :items_debug,
    :items,
    :line_totals,
    :order,
    :premium,
    :premium?,
    :profile,
    :route,
    :settings,
    :sum,
    :subtotal,
    :counter,
    :fallback,
    :skipped,
    :standard,
    :tier,
    :user,
    :user_id,
    :value,
    :amount,
    :params,
    :after,
    :source,
    :label,
    :limit,
    :over,
    :default,
    :matches?,
    :from,
    :in,
    :path,
    :map,
    :name,
    :dep,
    :JidoTest,
    :TestActions,
    :Add,
    :Double,
    :FlowFunctions,
    :LoadItems
  ]

  describe "parse/2" do
    test "builds action step flows from restricted script source" do
      flow =
        Script.parse!(
          """
          flow :scripted_math do
            step :add, JidoTest.TestActions.Add, params: %{amount: 2}
            step :double, JidoTest.TestActions.Double, after: :add
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert %Flow{
               name: :scripted_math,
               flow: [
                 %{type: :step, name: :add, action: Add, params: %{amount: 2}, after: nil},
                 %{type: :step, name: :double, action: Double, params: %{}, after: :add}
               ]
             } = flow

      assert {:ok, result} = Exec.run(flow, %{value: 3})
      assert %{add: [%{value: 5}], double: [%{value: 10}]} = Exec.results(result)
    end

    test "builds map, reduce, and accumulate primitives" do
      flow =
        Script.parse!(
          """
          flow :scripted_primitives do
            map :double_each, {JidoTest.TestActions.FlowFunctions, :double}
            reduce :sum, 0, {JidoTest.TestActions.FlowFunctions, :sum}, after: :double_each, map: :double_each
            accumulate :counter, 0, &JidoTest.TestActions.FlowFunctions.sum/2, after: :sum
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert [
               %{type: :map, name: :double_each, mapper: {FlowFunctions, :double}},
               %{type: :reduce, name: :sum, reducer: {FlowFunctions, :sum}, map: :double_each},
               %{type: :accumulate, name: :counter, reducer: {FlowFunctions, :sum}}
             ] = flow.flow

      assert {:ok, result} = Exec.run(flow, [1, 2, 3])
      results = Exec.results(result)

      assert 12 in results.sum
    end

    test "builds explicit projection bridges from action outputs into primitives" do
      flow =
        Script.parse!(
          """
          flow :scripted_projection do
            step :load_items, JidoTest.TestActions.LoadItems, params: %{items: [1, 2, 3]}
            project :items, from: :load_items, path: [:items]
            map :double_each, {JidoTest.TestActions.FlowFunctions, :double}, after: :items
            reduce :sum, 0, {JidoTest.TestActions.FlowFunctions, :sum}, after: :double_each, map: :double_each
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert %{flow: [%{type: :step}, %{type: :project}, %{type: :map}, %{type: :reduce}]} =
               Flow.to_map(flow)

      assert {:ok, result} = Exec.run(flow, %{})

      assert %{
               load_items: [%{items: [1, 2, 3]}],
               items: [[1, 2, 3]],
               sum: [12]
             } = Exec.results(result)
    end

    test "expands script-time loop blocks into concrete flow entries" do
      flow =
        Script.parse!(
          """
          flow :scripted_loop do
            loop {name, amount, dep}, in: [
              {:add_one, 1, nil},
              {:add_two, 2, :add_one}
            ] do
              step name, JidoTest.TestActions.Add, params: %{amount: amount}, after: dep
            end
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert [
               %{name: :add_one, params: %{amount: 1}, after: nil},
               %{name: :add_two, params: %{amount: 2}, after: :add_one}
             ] = flow.flow

      assert {:ok, result} = Exec.run(flow, %{value: 0})
      assert %{add_one: [%{value: 1}], add_two: [%{value: 3}]} = Exec.results(result)
    end

    test "rejects Elixir for comprehensions as flow syntax" do
      assert {:error, %ArgumentError{message: message}} =
               Script.parse(
                 """
                 flow :scripted_loop do
                   for {name, amount, dep} <- [
                     {:add_one, 1, nil}
                   ] do
                     step name, JidoTest.TestActions.Add, params: %{amount: amount}, after: dep
                   end
                 end
                 """,
                 allowed_atoms: @script_atoms
               )

      assert message =~ "unsupported flow script expression"
    end

    test "does not intern unknown atoms while parsing script strings" do
      unique = "script_atom_#{System.unique_integer([:positive])}"

      assert {:error, %ArgumentError{message: message}} =
               Script.parse("flow :#{unique} do\nend")

      assert message =~ "unsafe atom does not exist"
    end

    test "rejects unsupported runtime expressions instead of evaluating arbitrary code" do
      assert {:error, %ArgumentError{message: message}} =
               Script.parse(
                 """
                 flow :bad do
                   step :add, JidoTest.TestActions.Add, params: %{amount: String.to_integer("1")}
                 end
                 """,
                 allowed_atoms: @script_atoms ++ [:String, :to_integer]
               )

      assert message =~ "unsupported script value"
    end

    test "rejects Elixir if as flow syntax" do
      assert {:error, %ArgumentError{message: message}} =
               Script.parse(
                 """
                 flow :scripted_if do
                   if true do
                     step :add, JidoTest.TestActions.Add
                   end
                 end
                 """,
                 allowed_atoms: @script_atoms
               )

      assert message =~ "unsupported flow script expression"
    end

    test "builds lossless IR for block syntax and inspection components" do
      flow =
        Script.parse!(
          """
          flow :scripted_surface do
            input(:cart_id)

            chain do
              step :load_items, JidoTest.TestActions.LoadItems do
                argument(:items, value([1, 2, 3]))
              end

              debug :items_debug do
                source(result(:load_items, [:items]))
                label("loaded items")
                limit(5)
              end

              map :double_each, &JidoTest.TestActions.FlowFunctions.double/1 do
                source(result(:items_debug))
              end

              reduce :sum do
                source(result(:double_each))
                init(0)
                run(&JidoTest.TestActions.FlowFunctions.sum/2)
              end

              step :format, JidoTest.TestActions.Add do
                argument(:value, result(:sum))
                argument(:amount, value(1))
              end
            end

            trace(:loaded_items, source: result(:format))
            return(result(:format))
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert %Flow{
               name: :scripted_surface,
               inputs: [:cart_id],
               return: {:result, :format},
               flow: [
                 %{
                   type: :chain,
                   flow: [
                     %{
                       type: :step,
                       name: :load_items,
                       params: %{items: {:value, [1, 2, 3]}}
                     },
                     %{
                       type: :debug,
                       name: :items_debug,
                       source: {:result, :load_items, [:items]},
                       label: "loaded items",
                       limit: 5
                     },
                     %{type: :map, name: :double_each, source: {:result, :items_debug}},
                     %{
                       type: :reduce,
                       name: :sum,
                       source: {:result, :double_each},
                       init: 0,
                       reducer: {FlowFunctions, :sum}
                     },
                     %{
                       type: :step,
                       name: :format,
                       params: %{value: {:result, :sum}, amount: {:value, 1}}
                     }
                   ]
                 },
                 %{type: :trace, name: :loaded_items, source: {:result, :format}}
               ]
             } = flow
    end

    test "parses fanout and collect as structural IR" do
      flow =
        Script.parse!(
          """
          flow :scripted_fanout do
            input(:user_id)

            step :load_user, JidoTest.TestActions.BasicAction do
              argument(:value, input(:user_id))
            end

            fanout :load_user do
              step :load_profile, JidoTest.TestActions.NoParamsAction
              step :load_settings, JidoTest.TestActions.NoParamsAction
            end

            collect :dashboard do
              argument(:user, result(:load_user))
              argument(:profile, result(:load_profile))
              argument(:settings, result(:load_settings))
            end

            return(result(:dashboard))
          end
          """,
          allowed_atoms: @script_atoms ++ [:BasicAction, :NoParamsAction]
        )

      assert [
               %{type: :step, name: :load_user, params: %{value: {:input, :user_id}}},
               %{
                 type: :fanout,
                 from: :load_user,
                 flow: [
                   %{type: :step, name: :load_profile},
                   %{type: :step, name: :load_settings}
                 ]
               },
               %{
                 type: :collect,
                 name: :dashboard,
                 arguments: %{
                   user: {:result, :load_user},
                   profile: {:result, :load_profile},
                   settings: {:result, :load_settings}
                 }
               }
             ] = flow.flow

      assert flow.return == {:result, :dashboard}
    end

    test "lowers path-based over sugar to explicit project IR" do
      flow =
        Script.parse!(
          """
          flow :scripted_projection do
            step :load_items, JidoTest.TestActions.LoadItems, params: %{items: [1, 2, 3]}

            map :double_each,
              &JidoTest.TestActions.FlowFunctions.double/1,
              over: {:items, from: :load_items, path: [:items]}
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert [
               %{type: :step, name: :load_items},
               %{
                 type: :project,
                 name: :items,
                 from: :load_items,
                 path: [:items],
                 after: :load_items
               },
               %{
                 type: :map,
                 name: :double_each,
                 source: {:result, :items},
                 after: :items
               }
             ] = flow.flow
    end

    test "parses compact and block switch forms as IR" do
      compact =
        Script.parse!(
          """
          flow :scripted_switch do
            step :load_order, JidoTest.TestActions.NoParamsAction

            switch(:route,
              on: result(:load_order),
              matches?: [
                enterprise: {&JidoTest.TestActions.FlowFunctions.enterprise?/1, :enterprise},
                premium: {&JidoTest.TestActions.FlowFunctions.premium?/1, :premium}
              ],
              default: :standard,
              return: true
            )
          end
          """,
          allowed_atoms: @script_atoms ++ [:NoParamsAction]
        )

      assert [
               %{type: :step, name: :load_order},
               %{
                 type: :switch,
                 name: :route,
                 on: {:result, :load_order},
                 matches: [
                   %{
                     name: :enterprise,
                     predicate: {FlowFunctions, :enterprise?},
                     then: :enterprise
                   },
                   %{name: :premium, predicate: {FlowFunctions, :premium?}, then: :premium}
                 ],
                 default: :standard,
                 return?: true
               }
             ] = compact.flow

      block =
        Script.parse!(
          """
          flow :scripted_switch do
            step :load_order, JidoTest.TestActions.NoParamsAction

            switch :route do
              on(result(:load_order))

              matches? :premium, &JidoTest.TestActions.FlowFunctions.premium?/1 do
                step :premium, JidoTest.TestActions.NoParamsAction
                return(result(:premium))
              end

              default do
                step :standard, JidoTest.TestActions.NoParamsAction
                return(result(:standard))
              end
            end
          end
          """,
          allowed_atoms: @script_atoms ++ [:NoParamsAction]
        )

      assert [
               %{type: :step, name: :load_order},
               %{
                 type: :switch,
                 name: :route,
                 on: {:result, :load_order},
                 matches: [
                   %{
                     name: :premium,
                     predicate: {FlowFunctions, :premium?},
                     flow: [%{type: :step, name: :premium}],
                     return: {:result, :premium}
                   }
                 ],
                 default: %{
                   flow: [%{type: :step, name: :standard}],
                   return: {:result, :standard}
                 }
               }
             ] = block.flow
    end

    test "round-trips script through normalized script projection" do
      flow =
        Script.parse!(
          """
          flow :scripted_round_trip do
            input(:value)

            map :double_each, {JidoTest.TestActions.FlowFunctions, :double}, over: :items

            accumulate :counter do
              init(0)
              run({JidoTest.TestActions.FlowFunctions, :sum})
            end

            return(result(:counter))
          end
          """,
          allowed_atoms: @script_atoms
        )

      projected = Script.to_script(flow)

      assert %Flow{} = reparsed = Script.parse!(projected, allowed_atoms: @script_atoms)
      assert Flow.to_map(reparsed) == Flow.to_map(flow)
    end
  end
end
