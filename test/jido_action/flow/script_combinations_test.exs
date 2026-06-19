defmodule JidoTest.FlowScriptCombinationsTest do
  use JidoTest.ActionCase, async: true

  alias JidoTest.TestActions.FlowFunctions

  describe "syntax combinations" do
    test "round-trips focused syntax snippets through Flow Script IR" do
      cases = [
        {"empty flow", "",
         fn flow ->
           assert flow.flow == []
           assert flow.return == nil
         end},
        {"step with params, context, and dependency",
         """
         step :add, JidoTest.TestActions.Add,
           params: %{amount: 2},
           context: %{trace_id: "trace"},
           after: :load_user
         """,
         fn flow ->
           assert [
                    %{
                      type: :step,
                      name: :add,
                      params: %{amount: 2},
                      context: %{trace_id: "trace"},
                      after: :load_user
                    }
                  ] = flow.flow
         end},
        {"step argument block with mixed refs and wait_for",
         """
         step :format, JidoTest.TestActions.Add do
           argument(:value, result(:sum))
           argument(:amount, value(1))
           wait_for([:sum, :items])
         end
         """,
         fn flow ->
           assert [
                    %{
                      type: :step,
                      name: :format,
                      params: %{value: {:result, :sum}, amount: {:value, 1}},
                      after: [:sum, :items]
                    }
                  ] = flow.flow
         end},
        {"step with keyword params and context",
         """
         step :add, JidoTest.TestActions.Add,
           params: [amount: 2],
           context: [trace_id: "trace"]
         """,
         fn flow ->
           assert [%{type: :step, params: %{amount: 2}, context: %{trace_id: "trace"}}] =
                    flow.flow
         end},
        {"project path", "project :items, from: :load_items, path: [:items]",
         fn flow ->
           assert [%{type: :project, name: :items, from: :load_items, path: [:items]}] =
                    flow.flow
         end},
        {"map without source", "map :double_each, {JidoTest.TestActions.FlowFunctions, :double}",
         fn flow ->
           assert [%{type: :map, name: :double_each, source: nil, after: nil}] = flow.flow
         end},
        {"map with source block",
         """
         map :double_each, &JidoTest.TestActions.FlowFunctions.double/1 do
           source(result(:items))
         end
         """,
         fn flow ->
           assert [%{type: :map, source: {:result, :items}, after: :items}] = flow.flow
         end},
        {"map with lossless path over",
         """
         map :double_each, &JidoTest.TestActions.FlowFunctions.double/1,
           over: {:items, from: :load_items, path: [:items]}
         """,
         fn flow ->
           assert [
                    %{
                      type: :map,
                      source: nil,
                      over: {:items, from: :load_items, path: [:items]},
                      after: :items
                    }
                  ] = flow.flow
         end},
        {"map with result source and Runic IO options",
         """
         map :line_totals, {:mfa, JidoTest.TestActions.FlowFunctions, :double},
           source: result(:items),
           inputs: [input: :value],
           outputs: [output: :value]
         """,
         fn flow ->
           assert [
                    %{
                      type: :map,
                      mapper: {:mfa, FlowFunctions, :double},
                      source: {:result, :items},
                      inputs: [input: :value],
                      outputs: [output: :value]
                    }
                  ] = flow.flow
         end},
        {"reduce inline with map fan-in",
         """
         reduce :sum, 0, {JidoTest.TestActions.FlowFunctions, :sum},
           after: :double_each,
           map: :double_each
         """,
         fn flow ->
           assert [%{type: :reduce, name: :sum, map: :double_each, after: :double_each}] =
                    flow.flow
         end},
        {"reduce block with source",
         """
         reduce :sum do
           source(result(:double_each))
           init(0)
           run(&JidoTest.TestActions.FlowFunctions.sum/2)
         end
         """,
         fn flow ->
           assert [
                    %{
                      type: :reduce,
                      source: {:result, :double_each},
                      map: :double_each,
                      reducer: {FlowFunctions, :sum}
                    }
                  ] = flow.flow
         end},
        {"accumulate inline",
         "accumulate :counter, 0, {JidoTest.TestActions.FlowFunctions, :sum}, after: :sum",
         fn flow ->
           assert [%{type: :accumulate, name: :counter, source: nil, after: :sum}] =
                    flow.flow
         end},
        {"accumulate block with source",
         """
         accumulate :counter do
           source(result(:sum))
           init(0)
           run({JidoTest.TestActions.FlowFunctions, :sum})
         end
         """,
         fn flow ->
           assert [%{type: :accumulate, source: {:result, :sum}, after: :sum}] = flow.flow
         end},
        {"chain block",
         """
         chain do
           step :add, JidoTest.TestActions.Add, params: %{amount: 1}
           step :double, JidoTest.TestActions.Double
         end
         """,
         fn flow ->
           assert [%{type: :chain, flow: [%{name: :add}, %{name: :double}]}] = flow.flow
         end},
        {"fanout block",
         """
         fanout :load_user do
           step :load_profile, JidoTest.TestActions.NoParamsAction
           step :load_settings, JidoTest.TestActions.NoParamsAction
         end
         """,
         fn flow ->
           assert [
                    %{
                      type: :fanout,
                      from: :load_user,
                      flow: [%{name: :load_profile}, %{name: :load_settings}]
                    }
                  ] = flow.flow
         end},
        {"collect block",
         """
         collect :dashboard do
           argument(:user, result(:load_user))
           argument(:profile, result(:load_profile))
         end
         """,
         fn flow ->
           assert [
                    %{
                      type: :collect,
                      arguments: %{user: {:result, :load_user}, profile: {:result, :load_profile}},
                      after: after_dep
                    }
                  ] = flow.flow

           assert MapSet.new(after_dep) == MapSet.new([:load_user, :load_profile])
         end},
        {"debug block with inspection fields",
         """
         debug :items_debug do
           source(result(:load_items, [:items]))
           label("loaded items")
           limit(5)
         end
         """,
         fn flow ->
           assert [
                    %{
                      type: :debug,
                      source: {:result, :load_items, [:items]},
                      label: "loaded items",
                      limit: 5,
                      after: :load_items
                    }
                  ] = flow.flow
         end},
        {"debug marker without fields", "debug :fallback",
         fn flow ->
           assert [%{type: :debug, source: nil, label: nil, limit: nil}] = flow.flow
         end},
        {"trace with and without source",
         """
         trace(:loaded_items, source: result(:format))
         trace(:fallback)
         """,
         fn flow ->
           assert [
                    %{type: :trace, source: {:result, :format}, after: :format},
                    %{type: :trace, source: nil, after: nil}
                  ] = flow.flow
         end},
        {"compact switch",
         """
         switch(:route,
           on: result(:load_order),
           matches?: [
             enterprise: {&JidoTest.TestActions.FlowFunctions.enterprise?/1, :enterprise},
             premium: {&JidoTest.TestActions.FlowFunctions.premium?/1, :premium}
           ],
           default: :standard,
           return: true
         )
         """,
         fn flow ->
           assert [
                    %{
                      type: :switch,
                      on: {:result, :load_order},
                      matches: [%{then: :enterprise}, %{then: :premium}],
                      default: :standard,
                      return?: true
                    }
                  ] = flow.flow
         end},
        {"compact switch with map literal targets",
         """
         switch(:route,
           on: result(:load_order),
           matches?: [
             premium: {&JidoTest.TestActions.FlowFunctions.premium?/1, %{route: :premium}}
           ],
           default: %{route: :standard},
           return: true
         )
         """,
         fn flow ->
           assert [
                    %{
                      type: :switch,
                      matches: [%{then: %{route: :premium}}],
                      default: %{route: :standard},
                      return?: true
                    }
                  ] = flow.flow
         end},
        {"block switch",
         """
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
         """,
         fn flow ->
           assert [
                    %{
                      type: :switch,
                      matches: [%{flow: [%{name: :premium}], return: {:result, :premium}}],
                      default: %{flow: [%{name: :standard}], return: {:result, :standard}}
                    }
                  ] = flow.flow
         end}
      ]

      for {label, body, assert_flow} <- cases do
        {flow, projected} = assert_script_round_trip(body)

        assert projected =~ "flow :scripted_combination do", label
        assert_flow.(flow)
      end
    end

    test "rejects invalid syntax combinations directly" do
      cases = [
        {"input reference type", "return(input(\"cart\"))",
         "input reference expects an atom name"},
        {"loop form",
         """
         loop amount, in: :items do
           step :add, JidoTest.TestActions.Add, params: %{amount: amount}
         end
         """, "unsupported flow script expression"},
        {"duplicate wait_for",
         """
         step :add, JidoTest.TestActions.Add do
           wait_for(:sum)
           wait_for(:items)
         end
         """, "wait_for can only be declared once"},
        {"duplicate argument",
         """
         step :add, JidoTest.TestActions.Add do
           argument(:amount, value(1))
           argument(:amount, value(2))
         end
         """, "argument :amount can only be declared once"},
        {"unsupported step block expression",
         """
         step :add, JidoTest.TestActions.Add do
           source(result(:items))
         end
         """, "unsupported step block expression"},
        {"unsupported collect block expression",
         """
         collect :dashboard do
           source(result(:load_user))
         end
         """, "unsupported collect block expression"},
        {"duplicate source field",
         """
         map :double_each, &JidoTest.TestActions.FlowFunctions.double/1 do
           source(result(:items))
           source(result(:load_items))
         end
         """, "source can only be declared once"},
        {"duplicate over option",
         """
         map :double_each, &JidoTest.TestActions.FlowFunctions.double/1,
           over: {:items, from: :load_items, from: :load_order, path: [:items]}
         """, "over option :from can only be declared once"},
        {"duplicate reduce field",
         """
         reduce :sum do
           init(0)
           init(1)
           run(&JidoTest.TestActions.FlowFunctions.sum/2)
         end
         """, "init can only be declared once"},
        {"debug label type",
         """
         debug :items_debug do
           label(:bad)
         end
         """, "debug label expects a string"},
        {"empty switch match",
         """
         switch :route do
           on(result(:load_order))

           matches? :premium, &JidoTest.TestActions.FlowFunctions.premium?/1 do
           end
         end
         """, "switch match cannot be empty"},
        {"duplicate switch default",
         """
         switch :route do
           on(result(:load_order))

           matches? :premium, &JidoTest.TestActions.FlowFunctions.premium?/1 do
             return(result(:premium))
           end

           default do
             return(result(:standard))
           end

           default do
             return(result(:fallback))
           end
         end
         """, "switch accepts default only once"},
        {"compact switch matches shape",
         "switch(:route, on: result(:load_order), matches?: [:bad])",
         "matches? expects a keyword list"},
        {"compact switch match tuple",
         "switch(:route, on: result(:load_order), matches?: [premium: :standard])",
         "switch match values must be {predicate, target} tuples"},
        {"compact switch return type",
         """
         switch(:route,
           on: result(:load_order),
           matches?: [premium: {&JidoTest.TestActions.FlowFunctions.premium?/1, :premium}],
           return: :yes
         )
         """, "switch return expects a boolean"}
      ]

      for {_label, body, expected} <- cases do
        assert_script_error(body, expected)
      end
    end
  end
end
