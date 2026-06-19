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
    :scripted_if,
    :scripted_surface,
    :scripted_round_trip,
    :scripted_switch,
    :scripted_fanout,
    :scripted_hardening,
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
    :element,
    :matches?,
    :from,
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

    test "rejects loop-like generation syntax" do
      assert {:error, %ArgumentError{message: message}} =
               Script.parse(
                 """
                 flow :scripted_hardening do
                   loop amount, in: [1] do
                     step :add, JidoTest.TestActions.Add, params: %{amount: amount}
                   end
                 end
                 """,
                 allowed_atoms: @script_atoms
               )

      assert message =~ "unsupported flow script expression"
    end

    test "rejects Elixir for comprehensions as flow syntax" do
      assert {:error, %ArgumentError{message: message}} =
               Script.parse(
                 """
                 flow :scripted_hardening do
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

    test "keeps path-based over syntax lossless in Flow IR and lowers at runtime" do
      flow =
        Script.parse!(
          """
          flow :scripted_projection do
            step :load_items, JidoTest.TestActions.LoadItems, params: %{items: [1, 2, 3]}

            map :double_each,
              &JidoTest.TestActions.FlowFunctions.double/1,
              over: {:items, from: :load_items, path: [:items]}

            reduce :sum, 0, &JidoTest.TestActions.FlowFunctions.sum/2, over: :double_each
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert [
               %{type: :step, name: :load_items},
               %{
                 type: :map,
                 name: :double_each,
                 over: {:items, from: :load_items, path: [:items]},
                 source: nil,
                 after: :items
               },
               %{
                 type: :reduce,
                 name: :sum,
                 over: :double_each,
                 source: nil,
                 after: :double_each
               }
             ] = flow.flow

      projected = Script.to_script(flow)
      assert projected =~ "over: {:items, from: :load_items, path: [:items]}"

      assert {:ok, result} = Exec.run(flow, %{})
      assert %{sum: [12]} = Exec.results(result)
    end

    test "parses and executes compact and block switch forms" do
      compact =
        Script.parse!(
          """
          flow :scripted_switch do
            switch(:route,
              on: input(:order),
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
               %{
                 type: :switch,
                 name: :route,
                 on: {:input, :order},
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

      assert {:ok, result} = Exec.run(compact, %{order: %{tier: :premium}})
      assert Exec.results(result).route == [:premium]

      assert {:ok, result} = Exec.run(compact, %{order: %{tier: :standard}})
      assert Exec.results(result).route == [:standard]

      block =
        Script.parse!(
          """
          flow :scripted_switch do
            switch :route do
              on(input(:order))

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
               %{
                 type: :switch,
                 name: :route,
                 on: {:input, :order},
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

      assert {:ok, result} = Exec.run(block, %{order: %{tier: :premium}})
      assert Exec.results(result).route == [%{result: "No params"}]

      assert {:ok, result} = Exec.run(block, %{order: %{tier: :standard}})
      assert Exec.results(result).route == [%{result: "No params"}]
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

    test "normalizes inline source atoms like block source atoms" do
      flow =
        Script.parse!(
          """
          flow :scripted_hardening do
            map :double_each, &JidoTest.TestActions.FlowFunctions.double/1, source: :items
            trace(:loaded_items, source: :double_each)
          end
          """,
          allowed_atoms: @script_atoms
        )

      assert [
               %{type: :map, source: {:result, :items}, after: :items},
               %{type: :trace, source: {:result, :double_each}, after: :double_each}
             ] = flow.flow
    end

    test "rejects malformed syntax with argument errors" do
      cases = [
        {"""
         flow :scripted_hardening, bad: true do
         end
         """, "unsupported flow option :bad"},
        {"""
         flow :scripted_hardening do
           step :add, JidoTest.TestActions.Add, bad: true
         end
         """, "unsupported step option :bad"},
        {"""
         flow :scripted_hardening do
           project :items, from: :load_items, path: [:items], bad: true
         end
         """, "unsupported project option :bad"},
        {"""
         flow :scripted_hardening do
           map :double_each, &JidoTest.TestActions.FlowFunctions.double/1, bad: true
         end
         """, "unsupported map option :bad"},
        {"""
         flow :scripted_hardening do
           reduce :sum, 0, &JidoTest.TestActions.FlowFunctions.sum/2, bad: true
         end
         """, "unsupported reduce option :bad"},
        {"""
         flow :scripted_hardening do
           accumulate :counter, 0, &JidoTest.TestActions.FlowFunctions.sum/2, bad: true
         end
         """, "unsupported accumulate option :bad"},
        {"""
         flow :scripted_hardening do
           chain bad: true do
             step :add, JidoTest.TestActions.Add
           end
         end
         """, "unsupported chain option :bad"},
        {"""
         flow :scripted_hardening do
           fanout :load_user, bad: true do
             step :load_profile, JidoTest.TestActions.NoParamsAction
           end
         end
         """, "unsupported fanout option :bad"},
        {"""
         flow :scripted_hardening do
           collect :dashboard, bad: true do
             argument(:user, result(:load_user))
           end
         end
         """, "unsupported collect option :bad"},
        {"""
         flow :scripted_hardening do
           debug :items_debug, bad: true
         end
         """, "unsupported debug option :bad"},
        {"""
         flow :scripted_hardening do
           trace :loaded_items, bad: true
         end
         """, "unsupported trace option :bad"},
        {"""
         flow :scripted_hardening do
           loop amount, in: [1], bad: true do
             step :add, JidoTest.TestActions.Add, params: %{amount: amount}
           end
         end
         """, "unsupported flow script expression"},
        {"""
         flow :scripted_hardening do
           switch :route, bad: true do
             on(result(:load_order))
           end
         end
         """, "unsupported switch option :bad"},
        {"""
         flow :scripted_hardening do
           chain do
           end
         end
         """, "chain cannot be empty"},
        {"""
         flow :scripted_hardening do
           fanout :load_user do
           end
         end
         """, "fanout cannot be empty"},
        {"""
         flow :scripted_hardening do
           collect :dashboard do
           end
         end
         """, "collect expects at least one argument"},
        {"""
         flow :scripted_hardening do
           reduce :sum do
             init(0)
           end
         end
         """, "reduce block expects init/1 and run/1"},
        {"""
         flow :scripted_hardening do
           accumulate :counter do
             run(&JidoTest.TestActions.FlowFunctions.sum/2)
           end
         end
         """, "accumulate block expects init/1 and run/1"},
        {"""
         flow :scripted_hardening do
           switch(:route, matches?: [])
         end
         """, "switch expects an :on option"},
        {"""
         flow :scripted_hardening do
           switch :route do
             default do
               step :standard, JidoTest.TestActions.NoParamsAction
             end
           end
         end
         """, "switch expects on/1"},
        {"""
         flow :scripted_hardening do
           debug :items_debug do
             source(result(:load_items, ["items"]))
           end
         end
         """, "result path expects a non-empty list of atoms or non-negative integers"},
        {"""
         flow :scripted_hardening do
           collect :dashboard do
             argument("user", result(:load_user))
           end
         end
         """, "argument name expects an atom"}
      ]

      for {source, expected} <- cases do
        assert {:error, %ArgumentError{message: message}} =
                 Script.parse(source,
                   allowed_atoms: @script_atoms ++ [:BasicAction, :NoParamsAction]
                 )

        assert message =~ expected
      end
    end

    test "rejects ambiguous or under-specified syntax" do
      cases = [
        {"""
         flow :scripted_hardening do
           return(result(:add))
           return(result(:double))
         end
         """, "return can only be declared once"},
        {"""
         flow :scripted_hardening do
           step :add, JidoTest.TestActions.Add, params: %{amount: 1} do
             argument(:amount, value(2))
           end
         end
         """, "step cannot combine params option with argument block"},
        {"""
         flow :scripted_hardening do
           project :items, from: :load_items, path: ["items"]
         end
         """, "project path expects a non-empty list of atoms or non-negative integers"},
        {"""
         flow :scripted_hardening do
           map :double_each, &JidoTest.TestActions.FlowFunctions.double/1,
             source: :items,
             over: :loaded_items
         end
         """, "map accepts only one source declaration"},
        {"""
         flow :scripted_hardening do
           debug :items_debug, source: :items do
             source(result(:load_items))
           end
         end
         """, "debug accepts only one source declaration"},
        {"""
         flow :scripted_hardening do
           debug :items_debug do
             source(element(:items))
           end
         end
         """, "expected input/1, result/1, result/2, or value/1"},
        {"""
         flow :scripted_hardening do
           switch(:route, on: result(:load_order), matches?: [])
         end
         """, "switch expects at least one matches? entry"},
        {"""
         flow :scripted_hardening do
           switch :route do
             on(result(:load_order))
             on(result(:load_profile))
           end
         end
         """, "switch accepts on/1 only once"},
        {"""
         flow :scripted_hardening do
           debug :items_debug do
             limit(0)
           end
         end
         """, "debug limit expects a positive integer"}
      ]

      for {source, expected} <- cases do
        assert {:error, %ArgumentError{message: message}} =
                 Script.parse(source, allowed_atoms: @script_atoms)

        assert message =~ expected
      end
    end
  end
end
