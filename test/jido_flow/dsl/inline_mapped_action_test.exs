defmodule Jido.Flow.DSL.InlineMappedActionTest do
  use ExUnit.Case, async: false

  defmodule Helpers do
    def decorate(value), do: "kept:" <> value
  end

  defmodule BodyHelpers do
    def action(value), do: %{value: value}
  end

  test "inline Map and Reduce keep source order and total doubled values" do
    owner =
      compile_flow("""
      map "doubled" do
        collection input(:items)
        action [value <- item() * 2, index <- item_index(), id <- item_id()] do
          {:ok, %{value: value, index: index, id: id}}
        end
      end
      reduce "total" do
        collection result("doubled")
        initial %{value: 0}
        action [value <- item(:value), total <- accumulator(:value)], context: ctx do
          send(ctx.test_pid, {:reduce, total, value})
          {:ok, %{value: total + value}}
        end
      end
      output %{items: result("doubled"), total: result("total", :value)}
      """)

    assert {:ok, %{items: items, total: 12}} =
             Jido.Exec.run(owner, %{items: [1, 2, 3]}, %{test_pid: self()})

    assert_received {:reduce, 0, 2}
    assert_received {:reduce, 2, 4}
    assert_received {:reduce, 6, 6}
    refute_received {:reduce, _, _}
    assert Enum.map(items, & &1.value) == [2, 4, 6]
    assert Enum.map(items, & &1.index) == [0, 1, 2]
    assert Enum.all?(items, &is_binary(&1.id))
    assert length(Enum.uniq_by(items, & &1.id)) == 3
    assert {:ok, %{items: [], total: 0}} = Jido.Exec.run(owner, %{items: []})

    assert [mapped, reduced] = owner.flow().components
    assert target(owner, map: "doubled", role: :action) == mapped.action
    assert target(owner, reduce: "total", role: :action) == reduced.action
    assert mapped.action.name() == "doubled"
    assert reduced.action.name() == "total"
    assert_raise ArgumentError, fn -> owner.step_action("doubled") end
  end

  test "each mapped slot accepts bound patterns, metadata, schemas, context, and owner helpers" do
    for slot <- slots() do
      owner =
        compile_flow(
          slot_source(slot, """
          action %{value: value} <- input(), name: "configured", description: "Adds one",
            schema: Z.object(%{value: Z.integer()}), output_schema: Z.object(%{value: Z.integer()}), context: ctx do
            {:ok, %{value: add(value) + ctx.extra}}
          end
          """),
          before: "alias Zoi, as: Z\n@amount 1",
          after: "defp add(value), do: value + @amount"
        )

      action = target(owner, slot_path(slot))
      assert action.name() == "configured"
      assert action.description() == "Adds one"
      assert {:ok, %{value: 6}} = Jido.Exec.run(action, %{value: 2}, %{extra: 3})

      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Jido.Exec.run(action, %{value: "bad"}, %{extra: 3})

      assert {:ok, _} = Jido.Exec.run(owner, %{value: 2}, %{extra: 3})
    end
  end

  test "Choice selects one target and keeps parent and fallback identities distinct" do
    owner =
      compile_flow("""
      choice "first" do
        option "otherwise" do
          condition input(:enabled)
          action [], context: ctx do
            send(ctx.test_pid, :first_option)
            {:ok, %{value: :option}}
          end
        end
        otherwise do
          action [], context: ctx do
            send(ctx.test_pid, :first_fallback)
            {:ok, %{value: :fallback}}
          end
        end
      end
      choice "second" do
        option "otherwise" do
          condition false
          action [], context: ctx do
            send(ctx.test_pid, :second_option)
            {:ok, %{}}
          end
        end
        otherwise do
          action value <- result("first", :value), context: ctx do
            send(ctx.test_pid, :second_fallback)
            {:ok, %{value: value}}
          end
        end
      end
      output result("second")
      """)

    actions =
      for choice <- ["first", "second"], branch <- [option: "otherwise", fallback: :otherwise] do
        target(owner, [choice: choice] ++ [branch] ++ [role: :action])
      end

    assert length(Enum.uniq(actions)) == 4
    assert Enum.all?(actions, &(&1.name() == "otherwise"))

    for {enabled, expected, marker} <- [
          {true, :option, :first_option},
          {false, :fallback, :first_fallback}
        ] do
      assert {:ok, %{value: ^expected}} =
               Jido.Exec.run(owner, %{enabled: enabled}, %{test_pid: self()})

      assert_received ^marker
      assert_received :second_fallback
      refute_received :first_option
      refute_received :first_fallback
      refute_received :second_option
    end
  end

  test "each mapped slot rejects callback headers with its location" do
    for slot <- slots(), header <- ["params", "%{value: value}"] do
      assert_raise CompileError,
                   ~r/#{slot_label(slot)} action: expected a binding in the form name <- source/,
                   fn ->
                     compile_flow(slot_source(slot, "action #{header}, do: {:ok, %{}}"))
                   end
    end
  end

  test "mapped slots reject source calls, pins, and reads of a bound variable" do
    for slot <- slots(),
        header <- [
          "value <- String.length(input(:value))",
          "value <- ^external",
          "[value <- input(:value), other <- value + 1]"
        ] do
      assert_raise CompileError,
                   ~r/inline Action binding source.*unsupported Flow expression/,
                   fn ->
                     compile_flow(slot_source(slot, "action #{header}, do: {:ok, %{}}"))
                   end
    end
  end

  test "all mapped field conflicts leave an existing wrapper unchanged in both orders" do
    inline = ~s|action [], name: "replacement", do: {:ok, %{value: :replacement}}|
    explicit = "action JidoActionTest.Fixtures.Actions.EchoParamsAction"
    params = "params %{}"

    for slot <- slots(),
        fields <- [
          [inline, inline],
          [inline, explicit],
          [explicit, inline],
          [inline, params],
          [params, inline]
        ] do
      owner = compile_flow(slot_source(slot, "action [], do: {:ok, %{value: :original}}"))
      action = target(owner, slot_path(slot))
      original = {action.name(), action.module_info(:md5)}

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError,
                     ~r/inline Action conflicts with an existing (action|params) field/,
                     fn ->
                       compile_flow(slot_source(slot, Enum.join(fields, "\n")), owner: owner)
                     end
      end)

      assert {action.name(), action.module_info(:md5)} == original
    end
  end

  test "a Choice parent field error does not replace either deferred child wrapper" do
    source = fn name, parent_field ->
      """
      choice "node" do
        option "selected" do
          condition true
          action [], name: "#{name}", do: {:ok, %{}}
        end
        otherwise do
          action [], name: "#{name}", do: {:ok, %{}}
        end
        #{parent_field}
      end
      output result("node")
      """
    end

    owner = compile_flow(source.("original", ""))
    actions = [target(owner, slot_path(:option)), target(owner, slot_path(:fallback))]
    original = Enum.map(actions, & &1.module_info(:md5))

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise Spark.Error.DslError, ~r/meta/, fn ->
        compile_flow(
          """
          try do
            #{source.("replacement", "meta :invalid")}
          after
            send(@test_pid, {:scope_after_failure, Module.get_attribute(__MODULE__, :__jido_flow_inline_scope__)})
          end
          """,
          owner: owner,
          before: ~s|@test_pid :erlang.list_to_pid(~c"#{:erlang.pid_to_list(self())}")|
        )
      end
    end)

    assert_received {:scope_after_failure, nil}
    assert Enum.map(actions, & &1.module_info(:md5)) == original
    assert Enum.all?(actions, &(&1.name() == "original"))
  end

  test "mapped declarations evaluate names once and ignore false declarations" do
    owner =
      compile_flow(
        """
        if false do
          map "unused" do
            collection []
            action [], do: {:ok, %{}}
          end
        end
        map (send(@test_pid, :map_name); "map name!") do
          collection []
          action [], do: {:ok, %{}}
        end
        reduce (send(@test_pid, :reduce_name); "reduce name!") do
          collection []
          initial %{}
          action [], do: {:ok, %{}}
        end
        choice (send(@test_pid, :choice_name); "choice name!") do
          if false do
            option "unused" do
              condition true
              action [], do: {:ok, %{}}
            end
          end
          option (send(@test_pid, :option_name); "option name!") do
            condition true
            action [], do: {:ok, %{}}
          end
          otherwise do
            if false, do: params(%{})
            action [], do: {:ok, %{}}
          end
        end
        iterate (send(@test_pid, :iterate_name); "iterate name!") do
          state [], initial: %{}
          action [], do: {:ok, %{}}
          repeat 1
        end
        output %{}
        """,
        before: ~s|@test_pid :erlang.list_to_pid(~c"#{:erlang.pid_to_list(self())}")|,
        after:
          "def scope_cleared?, do: unquote(is_nil(Module.get_attribute(__MODULE__, :__jido_flow_inline_scope__)))"
      )

    for marker <- [:map_name, :reduce_name, :choice_name, :option_name, :iterate_name] do
      assert_received ^marker
      refute_received ^marker
    end

    assert owner.scope_cleared?()
    assert map_size(owner.__jido_inline_actions__()) == 5
    assert {:ok, %{}} = Jido.Exec.run(owner)
  end

  test "mapped bindings keep skipped Expr operands in graph dependencies" do
    for slot <- slots() do
      declarations = """
      step "seed", [], do: {:ok, %{value: true}}
      #{slot_source(slot, ~s|action value <- false and result("seed", :value), do: {:ok, %{value: value}}|)}
      """

      owner = compile_flow(declarations)
      assert {:ok, dependencies} = Jido.Flow.dependencies(owner.flow())
      assert dependencies["node"].references == ["seed"]
      assert {:ok, _} = Jido.Exec.run(owner)

      assert_raise CompileError, ~r/unknown|missing/, fn ->
        compile_flow(
          slot_source(
            slot,
            ~s|action value <- false and result("missing", :value), do: {:ok, %{value: value}}|
          )
        )
      end

      assert_raise CompileError, ~r/cycle|itself/, fn ->
        compile_flow("""
        step "seed", value <- result("node"), do: {:ok, %{value: value}}
        #{slot_source(slot, ~s|action value <- false and result("seed", :value), do: {:ok, %{value: value}}|)}
        """)
      end
    end
  end

  test "mapped bindings use only the existing component reference scopes" do
    for {slot, source} <- [
          map: "accumulator()",
          reduce: "state()",
          option: "item()",
          fallback: "iteration_index()",
          iterate: "item()"
        ] do
      assert_raise CompileError, ~r/(scope|not allowed|not valid|not available)/, fn ->
        compile_flow(slot_source(slot, "action value <- #{source}, do: {:ok, %{value: value}}"))
      end
    end
  end

  test "invalid bound sources leave each existing wrapper and schema unchanged" do
    for {slot, source} <- [
          step: "item()",
          map: "accumulator()",
          reduce: "%{nested: [state()]}",
          option: "false and item()",
          fallback: "iteration_index()",
          iterate: "item()",
          map: "input([-1])",
          map: "unknown_source()"
        ] do
      fields = fn source, name, type ->
        """
        action value <- #{source}, name: "#{name}", schema: Zoi.object(%{value: Zoi.#{type}()}) do
          {:ok, %{value: value}}
        end
        """
      end

      owner = compile_flow(slot_source(slot, fields.("input(:value)", "original", :integer)))
      action = target(owner, slot_path(slot))
      original = {action.name(), action.schema(), action.module_info(:md5)}
      assert {:ok, _} = Jido.Exec.run(owner, %{value: 1})

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        error =
          try do
            compile_flow(
              slot_source(slot, fields.(source, "replacement", :string)),
              owner: owner
            )

            nil
          rescue
            error in CompileError -> error
          end

        assert action.name() == "original"
        assert {action.name(), action.schema(), action.module_info(:md5)} == original
        assert %CompileError{} = error
        assert error.description =~ ~r/(scope|reference path|unsupported Flow expression)/
      end)
    end
  end

  test "a Choice child source error preserves both deferred wrappers" do
    declarations = fn name, source ->
      """
      choice "node" do
        option "selected" do
          condition true
          action [], name: "#{name}", do: {:ok, %{value: 1}}
        end
        otherwise do
          action value <- #{source}, name: "#{name}", do: {:ok, %{value: value}}
        end
      end
      output result("node")
      """
    end

    owner = compile_flow(declarations.("original", "input(:value)"))
    actions = [target(owner, slot_path(:option)), target(owner, slot_path(:fallback))]
    original = Enum.map(actions, &{&1.name(), &1.module_info(:md5)})

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/inline Action binding source:.*valid scope/, fn ->
        compile_flow(declarations.("replacement", "item()"), owner: owner)
      end
    end)

    assert Enum.map(actions, &{&1.name(), &1.module_info(:md5)}) == original
  end

  test "inline fields preserve application aliases" do
    owner =
      compile_flow(
        slot_source(:map, """
        action [] do
          import #{inspect(BodyHelpers)}, only: [action: 1]
          {:ok, action(decorate(JidoFlowInlineFieldOptions.upcase("value")))}
        end
        """),
        before: """
        alias String, as: JidoFlowInlineFieldOptions
        import #{inspect(Helpers)}, only: [decorate: 1]
        """
      )

    assert {:ok, %{result: [%{value: "kept:VALUE"}]}} = Jido.Exec.run(owner)
  end

  test "Choice and Iterate State are not Action field slots" do
    for {label, declaration} <- [
          {"Choice",
           """
           choice "node" do
             action [], do: {:ok, %{}}
             otherwise action: JidoActionTest.Fixtures.Actions.EchoParamsAction, params: %{}
           end
           output result("node")
           """},
          {"Iterate state",
           """
           iterate "node" do
             state [] do
               initial %{}
               action [], do: {:ok, %{}}
             end
             action [], do: {:ok, %{}}
             repeat 1
           end
           output result("node")
           """}
        ] do
      assert_raise CompileError, ~r/#{label} does not accept an inline Action field/, fn ->
        compile_flow(declaration)
      end
    end
  end

  test "Map keeps ordered collected errors after reversed completion and in step-wise execution" do
    owner = compile_flow(map_errors_source(:collect_errors))
    explicit = explicit_map(owner, :collect_errors)
    assert explicit == owner.flow()

    results =
      for flow <- [owner, explicit] do
        ref = make_ref()
        test_pid = self()

        task =
          Task.async(fn ->
            Jido.Exec.run(
              flow,
              %{items: [1, 2, 3]},
              %{test_pid: test_pid, ref: ref, barrier?: true},
              max_concurrency: 3
            )
          end)

        try do
          workers =
            for item <- [1, 2, 3], into: %{} do
              assert_receive {^ref, :item, ^item, pid}, 1_000
              {item, pid}
            end

          for item <- [3, 2, 1] do
            monitor = Process.monitor(workers[item])
            send(workers[item], {ref, :release})
            assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
          end

          assert {:ok,
                  %{
                    items: [
                      %{status: :ok, value: %{value: 2}},
                      %{status: :error, error: error},
                      %{status: :ok, value: %{value: 6}}
                    ]
                  }} = result = Task.await(task)

          assert error.message == "bad item"
          assert error.details.item_index == 1
          assert error.details.target == target(owner, map: "node", role: :action)
          result
        after
          Task.shutdown(task, :brutal_kill)
        end
      end

    assert [expected, expected] = results

    for flow <- [owner, explicit] do
      ref = make_ref()

      assert stepwise(flow, %{items: [1, 2, 3]}, %{test_pid: self(), ref: ref, barrier?: false}) ==
               expected

      for item <- [1, 2, 3], do: assert_received({^ref, :item, ^item, _})
      refute_received {^ref, :item, _, _}
    end
  end

  test "Map fail-fast matches explicit and step-wise target failure contracts" do
    owner = compile_flow(map_errors_source(:fail_fast))
    explicit = explicit_map(owner, :fail_fast)

    failures =
      for flow <- [owner, explicit], mode <- [:run, :stepwise] do
        ref = make_ref()
        context = %{test_pid: self(), ref: ref, barrier?: false}

        result =
          case mode do
            :run -> Jido.Exec.run(flow, %{items: [1, 2, 3]}, context, max_concurrency: 1)
            :stepwise -> stepwise(flow, %{items: [1, 2, 3]}, context, max_concurrency: 1)
          end

        assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} = result
        assert error.details.item_index == 1
        assert_received {^ref, :item, 2, _}

        for item <- [1, 3] do
          receive do
            {^ref, :item, ^item, _} -> :ok
          after
            0 -> :ok
          end
        end

        Jido.Action.Error.to_map(error)
      end

    assert length(Enum.uniq(failures)) == 1
  end

  test "Reduce preserves serial source order, empty input, and failures in both execution modes" do
    owner =
      compile_flow("""
      reduce "node" do
        collection input(:items)
        initial %{value: 0}
        action [value <- item(), total <- accumulator(:value), index <- item_index()], context: ctx do
          send(ctx.test_pid, {:fold, index, total, value})
          if ctx.fail? and value == 2 do
            {:error, Jido.Action.Error.execution_error("fold failed")}
          else
            {:ok, %{value: total * 10 + value}}
          end
        end
      end
      output result("node")
      """)

    explicit =
      Jido.Flow.new!(
        name: "mapped_inline_test",
        components: [
          Jido.Flow.Reduce.new!(
            name: "node",
            action: target(owner, reduce: "node", role: :action),
            collection: Jido.Flow.Ref.input(:items),
            initial: %{value: 0},
            params: %{
              value: Jido.Flow.Ref.item(),
              total: Jido.Flow.Ref.accumulator(:value),
              index: Jido.Flow.Ref.item_index()
            }
          )
        ],
        output: Jido.Flow.Ref.result("node")
      )

    assert explicit == owner.flow()

    failures =
      for flow <- [owner, explicit], mode <- [:run, :stepwise] do
        run = fn items, fail? ->
          context = %{test_pid: self(), fail?: fail?}

          case mode do
            :run -> Jido.Exec.run(flow, %{items: items}, context)
            :stepwise -> stepwise(flow, %{items: items}, context)
          end
        end

        assert {:ok, %{value: 123}} = run.([1, 2, 3], false)
        assert_received {:fold, 0, 0, 1}
        assert_received {:fold, 1, 1, 2}
        assert_received {:fold, 2, 12, 3}
        refute_received {:fold, _, _, _}
        assert {:ok, %{value: 0}} = run.([], false)
        refute_received {:fold, _, _, _}

        assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "fold failed"} = error} =
                 run.([1, 2, 3], true)

        assert_received {:fold, 0, 0, 1}
        assert_received {:fold, 1, 1, 2}
        refute_received {:fold, _, _, _}
        Jido.Action.Error.to_map(error)
      end

    assert length(Enum.uniq(failures)) == 1
  end

  test "Iterate keeps prior body results, state validation, completion, and bounds" do
    owner = compile_flow(iterate_source("while state(:count) < input(:limit)\nmax_iterations 3"))
    explicit = explicit_iterate(owner)
    assert explicit == owner.flow()

    for flow <- [owner, explicit], mode <- [:run, :stepwise] do
      context = %{test_pid: self()}

      run = fn input, context ->
        case mode do
          :run -> Jido.Exec.run(flow, input, context)
          :stepwise -> stepwise(flow, input, context)
        end
      end

      assert {:ok, %{iterations: 3, state: %{count: 3}, output: %{count: 3}}} =
               run.(%{initial: %{count: 0}, limit: 3}, context)

      assert_received {:iteration, 0, nil}
      assert_received {:iteration, 1, %{count: 1}}
      assert_received {:iteration, 2, %{count: 2}}
      refute_received {:iteration, _, _}

      assert {:ok, %{iterations: 0, state: %{count: 3}, output: nil}} =
               run.(%{initial: %{count: 3}, limit: 3}, context)

      refute_received {:iteration, _, _}

      assert {:error, %{message: "flow iterator exhausted maximum iterations"}} =
               run.(%{initial: %{count: 0}, limit: 4}, context)

      for index <- [0, 1, 2], do: assert_received({:iteration, ^index, _})
      refute_received {:iteration, _, _}

      assert {:error, _} = run.(%{initial: %{count: "bad"}, limit: 3}, context)
      refute_received {:iteration, _, _}

      assert {:error, error} =
               run.(%{initial: %{count: 0}, limit: 3}, Map.put(context, :invalid_state?, true))

      assert error.details.phase == :iterate_state_update
      assert_received {:iteration, 0, nil}
      refute_received {:iteration, _, _}

      assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "body failed"}} =
               run.(%{initial: %{count: 0}, limit: 3}, Map.put(context, :fail?, true))

      assert_received {:iteration, 0, nil}
      assert_received {:iteration, 1, %{count: 1}}
      refute_received {:iteration, _, _}
    end

    repeated = compile_flow(iterate_source("repeat 2"))

    assert {:ok, %{iterations: 2, state: %{count: 2}}} =
             Jido.Exec.run(repeated, %{initial: %{count: 0}}, %{test_pid: self()})

    assert_received {:iteration, 0, nil}
    assert_received {:iteration, 1, %{count: 1}}
    refute_received {:iteration, _, _}
  end

  defp map_errors_source(on_error),
    do: """
    map "node" do
      collection input(:items)
      on_error :#{on_error}
      action value <- item(), context: ctx do
        send(ctx.test_pid, {ctx.ref, :item, value, self()})
        if ctx.barrier? do
          receive do
            {ref, :release} when ref == ctx.ref -> :ok
          end
        end
        if value == 2 do
          {:error, Jido.Action.Error.execution_error("bad item", retry: false)}
        else
          {:ok, %{value: value * 2}}
        end
      end
    end
    output %{items: result("node")}
    """

  defp explicit_map(owner, on_error) do
    Jido.Flow.new!(
      name: "mapped_inline_test",
      components: [
        Jido.Flow.Map.new!(
          name: "node",
          action: target(owner, map: "node", role: :action),
          collection: Jido.Flow.Ref.input(:items),
          params: %{value: Jido.Flow.Ref.item()},
          on_error: on_error
        )
      ],
      output: %{items: Jido.Flow.Ref.result("node")}
    )
  end

  defp iterate_source(completion),
    do: """
    iterate "node" do
      state Zoi.object(%{count: Zoi.integer()}), initial: input(:initial)
      action [count <- state(:count), index <- iteration_index(), prior <- body_result()], context: ctx do
        send(ctx.test_pid, {:iteration, index, prior})
        if ctx[:fail?] && index == 1 do
          {:error, Jido.Action.Error.execution_error("body failed")}
        else
          {:ok, %{count: if(ctx[:invalid_state?], do: "bad", else: count + 1)}}
        end
      end
      update %{count: body_result(:count)}
      #{completion}
    end
    output result("node")
    """

  defp explicit_iterate(owner) do
    Jido.Flow.new!(
      name: "mapped_inline_test",
      components: [
        Jido.Flow.Iterate.new!(
          name: "node",
          action: target(owner, iterate: "node", role: :action),
          params: %{
            count: Jido.Flow.Ref.state(:count),
            index: Jido.Flow.Ref.iteration_index(),
            prior: Jido.Flow.Ref.body_result()
          },
          state:
            Jido.Flow.Iterate.State.new!(
              schema: Zoi.object(%{count: Zoi.integer()}),
              initial: Jido.Flow.Ref.input(:initial),
              update: %{count: Jido.Flow.Ref.body_result(:count)}
            ),
          completion:
            Jido.Flow.Condition.not(
              Jido.Flow.Condition.lt(Jido.Flow.Ref.state(:count), Jido.Flow.Ref.input(:limit))
            ),
          max_iterations: 3
        )
      ],
      output: Jido.Flow.Ref.result("node")
    )
  end

  defp stepwise(flow, input, context, options \\ []) do
    assert {:ok, execution} = Jido.Exec.start(flow, input, context, options)
    assert {:ok, execution} = Jido.Exec.continue(execution)
    Jido.Exec.result(execution)
  end

  defp slots, do: [:map, :reduce, :option, :fallback, :iterate]
  defp slot_path(:option), do: [choice: "node", option: "selected", role: :action]
  defp slot_path(:fallback), do: [choice: "node", fallback: :otherwise, role: :action]
  defp slot_path(slot), do: [{slot, "node"}, {:role, :action}]
  defp slot_label(:option), do: "Choice option"
  defp slot_label(:fallback), do: "Choice fallback"
  defp slot_label(slot), do: slot |> Atom.to_string() |> String.capitalize()

  defp slot_source(:step, fields),
    do: """
    step "node" do
      #{fields}
    end
    output result("node")
    """

  defp slot_source(:map, fields),
    do: """
    map "node" do
      collection [1]
      #{fields}
    end
    output %{result: result("node")}
    """

  defp slot_source(:reduce, fields),
    do: """
    reduce "node" do
      collection [1]
      initial %{}
      #{fields}
    end
    output result("node")
    """

  defp slot_source(:option, fields),
    do: """
    choice "node" do
      option "selected" do
        condition true
        #{fields}
      end
      otherwise action: JidoActionTest.Fixtures.Actions.EchoParamsAction, params: %{}
    end
    output result("node")
    """

  defp slot_source(:fallback, fields),
    do: """
    choice "node" do
      option "selected", condition: false, action: JidoActionTest.Fixtures.Actions.EchoParamsAction, params: %{}
      otherwise do
        #{fields}
      end
    end
    output result("node")
    """

  defp slot_source(:iterate, fields),
    do: """
    iterate "node" do
      state [], initial: %{}
      #{fields}
      repeat 1
    end
    output result("node")
    """

  defp target(owner, path), do: Jido.Action.Inline.target!(owner, [host: Jido.Flow] ++ path)

  defp compile_flow(declarations, options \\ []) do
    owner =
      Keyword.get_lazy(options, :owner, fn ->
        Module.concat(__MODULE__, "Owner#{System.unique_integer([:positive])}")
      end)

    loaded = MapSet.new(:code.all_loaded(), &elem(&1, 0))

    try do
      source = """
      defmodule #{inspect(owner)} do
        use Jido.Flow, name: "mapped_inline_test"
        #{Keyword.get(options, :before, "")}
        flow do
          #{declarations}
        end
        #{Keyword.get(options, :after, "")}
      end
      """

      task =
        Task.async(fn ->
          try do
            {:ok, Code.compile_string(source, "mapped_inline.ex")}
          rescue
            error -> {:error, error, __STACKTRACE__}
          end
        end)

      case Task.await(task, 30_000) do
        {:ok, _} -> :ok
        {:error, error, stacktrace} -> reraise error, stacktrace
      end

      owner
    after
      owned =
        for {module, _} <- :code.all_loaded(),
            not MapSet.member?(loaded, module),
            String.starts_with?(Atom.to_string(module), [
              "Elixir.Jido.Flow.DSL.InlineMappedActionTest.",
              "Elixir.Jido.Action.Generated.Inline.",
              "Elixir.Jido.Flow.Generated.InlineStep."
            ]),
            do: module

      on_exit(fn ->
        for module <- owned do
          :code.purge(module)
          :code.delete(module)
        end
      end)
    end
  end
end
