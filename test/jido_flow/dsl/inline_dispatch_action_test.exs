defmodule Jido.Flow.DSL.InlineDispatchActionTest do
  use ExUnit.Case, async: false

  defmodule Echo do
    use Jido.Action, name: "dispatch_echo"
    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule BodyHelpers do
    def decision(value), do: value + 1
    def expander(value), do: value + 2
  end

  defmodule Helpers do
    def decorate(value), do: value + 3
  end

  test "decision bindings resolve once and the callback expander receives the complete result" do
    owner =
      compile_flow("""
      dispatch "next" do
        decision value <- input(:value) + 1 do
          {:ok, %{value: value, raw: Jido.Flow.Ref.input(:other)}}
        end
        expander params do
          {:ok, params}
        end
      end
      output result("next")
      """)

    expected = %{value: 3, raw: Jido.Flow.Ref.input(:other)}
    assert {:ok, ^expected} = Jido.Exec.run(owner, %{value: 2, other: :not_resolved})
    assert [dispatch] = owner.flow().components
    assert dispatch.decision == target(owner, :decision)
    assert dispatch.expander == target(owner, :expander)
    refute dispatch.decision == dispatch.expander
    assert dispatch.decision.name() == "next"
    assert dispatch.expander.name() == "next"

    assert dispatch ==
             Jido.Flow.Dispatch.new!(
               name: "next",
               decision: target(owner, :decision),
               expander: target(owner, :expander),
               params: %{value: Jido.Expr.new!(:add, [Jido.Flow.Ref.input(:value), 1])}
             )

    refute Map.has_key?(dispatch, :expander_params)
    assert_raise ArgumentError, fn -> owner.step_action("next") end
  end

  test "decision accepts named, list, sole-map, and empty bound headers" do
    for {header, body, params, expected} <- [
          {"value <- input(:value)", "%{value: value}", %{value: Jido.Flow.Ref.input(:value)},
           %{value: 3}},
          {"[left <- input(:value), right <- 2]", "%{value: left + right}",
           %{left: Jido.Flow.Ref.input(:value), right: 2}, %{value: 5}},
          {"%{value: value} <- input()", "%{value: value}", Jido.Flow.Ref.input([]), %{value: 3}},
          {"[]", "%{value: 9}", %{}, %{value: 9}}
        ] do
      owner =
        compile_fields(
          "decision #{header}, do: {:ok, #{body}}\nexpander params, do: {:ok, params}"
        )

      assert [dispatch] = owner.flow().components
      assert dispatch.params == params
      assert {:ok, ^expected} = Jido.Exec.run(owner, %{value: 3})
    end
  end

  test "schemas validate resolved decision inputs and complete expander inputs before work" do
    owner =
      compile_fields("""
      decision value <- input(:value), name: "choose", description: "Makes a result",
        schema: Zoi.object(%{value: Zoi.integer()}), context: ctx do
        send(ctx.test_pid, :decision_started)
        {:ok, %{result: if(ctx[:bad?], do: "bad", else: value + ctx.increment), extra: :kept}}
      end
      expander %{result: result, extra: extra}, name: "expand", description: "Reads a result",
        schema: Zoi.object(%{result: Zoi.integer()}),
        output_schema: Zoi.object(%{value: Zoi.integer()}), context: ctx do
        send(ctx.test_pid, :expander_started)
        {:ok, %{value: if(ctx[:bad_output?], do: "bad", else: result + ctx.increment), extra: extra}}
      end
      """)

    decision = target(owner, :decision)
    expander = target(owner, :expander)
    assert {decision.name(), decision.description()} == {"choose", "Makes a result"}
    assert {expander.name(), expander.description()} == {"expand", "Reads a result"}
    context = %{test_pid: self(), increment: 2}
    assert {:ok, %{value: 7, extra: :kept}} = Jido.Exec.run(owner, %{value: 3}, context)
    assert_received :decision_started
    assert_received :expander_started

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.Exec.run(owner, %{value: "bad"}, context)

    refute_received :decision_started
    refute_received :expander_started

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.Exec.run(owner, %{value: 3}, Map.put(context, :bad?, true))

    assert_received :decision_started
    refute_received :expander_started

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.Exec.run(owner, %{value: 3}, Map.put(context, :bad_output?, true))

    assert_received :decision_started
    assert_received :expander_started
  end

  test "bound context is a parameter and callback context is the current execution context" do
    owner =
      compile_fields("""
      decision bound <- context(), context: current do
        {:ok, %{bound: bound.token, current: current.token}}
      end
      expander params, context: current do
        {:ok, Map.put(params, :expander_context, current.token)}
      end
      """)

    assert {:ok, %{bound: :original, current: :original, expander_context: :original}} =
             Jido.Exec.run(owner, %{}, %{token: :original})

    assert {:ok, %{bound: :saved, current: :new}} =
             Jido.Exec.run(target(owner, :decision), %{bound: %{token: :saved}}, %{token: :new})

    assert {:ok, %{value: :saved, expander_context: :new}} =
             Jido.Exec.run(target(owner, :expander), %{value: :saved}, %{token: :new})
  end

  test "explicit decision params and callback expander work in both field orders" do
    decision = "decision #{inspect(Echo)}"
    params = "params %{value: input(:value), raw: input(:raw)}"
    expander = "expander params, do: {:ok, params}"
    input = %{value: 3, raw: Jido.Flow.Ref.input(:never_resolve)}

    for fields <- [
          [decision, params, expander],
          [decision, expander, params],
          [params, expander, decision],
          [expander, params, decision]
        ] do
      owner = compile_fields(Enum.join(fields, "\n"))
      assert {:ok, ^input} = Jido.Exec.run(owner, input)
      assert [dispatch] = owner.flow().components
      assert dispatch.decision == Echo
      assert dispatch.expander == target(owner, :expander)
    end
  end

  test "inline decision and explicit expander work in both field orders" do
    decision = "decision value <- input(:value), do: {:ok, %{value: value, extra: :complete}}"
    expander = "expander #{inspect(Echo)}"

    for fields <- [[decision, expander], [expander, decision]] do
      owner = compile_fields(Enum.join(fields, "\n"))
      assert {:ok, %{value: 3, extra: :complete}} = Jido.Exec.run(owner, %{value: 3})
      assert [dispatch] = owner.flow().components
      assert dispatch.expander == Echo
      assert dispatch.decision == target(owner, :decision)
    end
  end

  test "all expander source-binding headers fail at their declaration location" do
    for header <- [
          "value <- input(:value)",
          "value <- context()",
          "value <- %{nested: input(:value)}",
          "value <- [input(:value), context()]",
          "%{value: value} <- input()",
          "[value <- input(:value)]",
          "[value <- input(:value), ctx <- context()]",
          "[]"
        ] do
      error =
        assert_raise CompileError,
                     ~r/Dispatch expander: inline Action callback requires a named variable or a map pattern/,
                     fn ->
                       compile_fields(
                         "decision [], do: {:ok, %{}}\nexpander #{header}, do: {:ok, %{}}"
                       )
                     end

      assert error.file == "dispatch_inline.ex"
      assert error.line == 7
    end
  end

  test "decision does not accept callback mode or unsupported source expressions" do
    for {header, message} <- [
          {"params", ~r/Dispatch decision: expected a binding/},
          {"%{value: value}", ~r/Dispatch decision: expected a binding/},
          {"value <- String.length(input(:value))", ~r/inline Action binding source/},
          {"value <- ^external", ~r/inline Action binding source/},
          {"[value <- input(:value), other <- value + 1]", ~r/inline Action binding source/}
        ] do
      error =
        assert_raise CompileError, message, fn ->
          compile_fields("decision #{header}, do: {:ok, %{}}\nexpander params, do: {:ok, params}")
        end

      assert error.file == "dispatch_inline.ex"
      assert error.line == 6
    end
  end

  test "Dispatch has no expander params option or field" do
    assert_raise Spark.Error.DslError, ~r/expander_params/, fn ->
      compile_flow("""
      dispatch "next", decision: #{inspect(Echo)}, expander: #{inspect(Echo)}, params: %{}, expander_params: %{}
      output result("next")
      """)
    end

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise CompileError, fn ->
        compile_fields(
          "decision [], do: {:ok, %{}}\nexpander params, do: {:ok, params}\nexpander_params %{}"
        )
      end
    end)
  end

  test "same-role and decision params conflicts do not replace either wrapper" do
    original =
      "decision [], name: \"original\", do: {:ok, %{}}\nexpander params, name: \"original\", do: {:ok, params}"

    for {role, other} <- [decision: :decision, decision: :params, expander: :expander],
        order <- [:inline_first, :explicit_first, :inline_twice] do
      owner = compile_fields(original)
      actions = [target(owner, :decision), target(owner, :expander)]
      signatures = Enum.map(actions, &{&1.name(), &1.module_info(:md5)})
      header = if role == :decision, do: "[]", else: "params"
      inline = "#{role} #{header}, name: \"replacement\", do: {:ok, %{}}"
      explicit = if other == :params, do: "params %{}", else: "#{other} #{inspect(Echo)}"

      fields =
        case order do
          :inline_first -> [inline, explicit]
          :explicit_first -> [explicit, inline]
          :inline_twice -> [inline, inline]
        end

      untouched =
        if role == :decision,
          do: "expander params, name: \"replacement\", do: {:ok, params}",
          else: "decision [], name: \"replacement\", do: {:ok, %{}}"

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError,
                     ~r/inline Action conflicts with an existing (decision|expander|params) field/,
                     fn ->
                       compile_fields(Enum.join([untouched | fields], "\n"), owner: owner)
                     end
      end)

      assert Enum.map(actions, &{&1.name(), &1.module_info(:md5)}) == signatures
    end
  end

  test "invalid options fail before wrappers change and restore the Flow scope" do
    fields = "decision [], do: {:ok, %{}}\nexpander params, do: {:ok, params}"
    owner = compile_fields(fields)
    actions = [target(owner, :decision), target(owner, :expander)]
    signatures = Enum.map(actions, & &1.module_info(:md5))

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise Spark.Error.DslError, ~r/meta/, fn ->
        compile_flow(
          """
          try do
            dispatch "next" do
              #{fields}
              meta :invalid
            end
          after
            send(@test_pid, {:restored_scope, Module.get_attribute(__MODULE__, :__jido_flow_inline_scope__)})
          end
          output result("next")
          """,
          owner: owner,
          before: test_pid_attribute()
        )
      end
    end)

    assert_received {:restored_scope, nil}
    assert Enum.map(actions, & &1.module_info(:md5)) == signatures
  end

  test "Dispatch names evaluate once, false declarations stay absent, and role paths stay stable" do
    owner =
      compile_flow(
        """
        if false do
          dispatch "absent" do
            decision [], do: {:ok, %{}}
            expander params, do: {:ok, params}
          end
        end
        dispatch (send(@test_pid, :name_evaluated); "next") do
          decision [], do: {:ok, %{value: :original}}
          expander params, do: {:ok, params}
        end
        output result("next")
        """,
        before: test_pid_attribute()
      )

    assert_received :name_evaluated
    refute_received :name_evaluated
    actions = [target(owner, :decision), target(owner, :expander)]
    assert length(Enum.uniq(actions)) == 2

    for role <- [:decision, :expander] do
      assert_raise ArgumentError, fn ->
        Jido.Action.Inline.target!(owner, host: Jido.Flow, dispatch: "absent", role: role)
      end
    end

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      compile_fields(
        "decision [], name: \"changed\", do: {:ok, %{value: :changed}}\nexpander params, name: \"changed\", do: {:ok, params}",
        owner: owner
      )
    end)

    assert [target(owner, :decision), target(owner, :expander)] == actions
    assert Enum.all?(actions, &(&1.name() == "changed"))
    assert {:ok, %{value: :changed}} = Jido.Exec.run(owner)
  end

  test "both bodies keep aliases, imports, private helpers, and declaration attributes" do
    owner =
      compile_fields(
        """
        decision value <- input(:value) do
          import #{inspect(BodyHelpers)}, only: [decision: 1]
          {:ok, %{value: decorate(decision(private_add(value)))}}
        end
        expander %{value: value} do
          import #{inspect(BodyHelpers)}, only: [expander: 1]
          {:ok, %{value: expander(JidoFlowInlineFieldOptions.decision(value))}}
        end
        """,
        before:
          "alias #{inspect(BodyHelpers)}, as: JidoFlowInlineFieldOptions\nimport #{inspect(Helpers)}, only: [decorate: 1]\n@amount 4",
        after: "defp private_add(value), do: value + @amount"
      )

    assert {:ok, %{value: 14}} = Jido.Exec.run(owner, %{value: 3})
  end

  test "both roles keep shared context and metadata option validation" do
    for role <- [:decision, :expander],
        {options, message} <- [
          {"context: value", ~r/context variable collides/},
          {"context: _", ~r/context must be a named variable/},
          {"name: \"one\", name: \"two\"", ~r/duplicate inline Action option/},
          {"after: []", ~r/unsupported inline Action option/},
          {"schema: Zoi.integer()", ~r/schema|configuration/}
        ] do
      header = if role == :decision, do: "value <- input(:value)", else: "value"

      other =
        if role == :decision, do: "expander #{inspect(Echo)}", else: "decision [], do: {:ok, %{}}"

      assert_raise CompileError, message, fn ->
        compile_fields("#{role} #{header}, #{options}, do: {:ok, %{value: value}}\n#{other}")
      end
    end
  end

  test "decision expressions keep dependencies and the existing Flow reference scope" do
    owner =
      compile_flow("""
      step "seed", [], do: {:ok, %{value: true}}
      dispatch "next" do
        decision value <- false and result("seed", :value), do: {:ok, %{value: value}}
        expander params, do: {:ok, params}
      end
      output result("next")
      """)

    assert {:ok, dependencies} = Jido.Flow.dependencies(owner.flow())
    assert dependencies["next"].references == ["seed"]
    assert {:ok, %{value: false}} = Jido.Exec.run(owner)

    for {source, message} <- [
          {"false and result(\"missing\", :value)", ~r/unknown|missing/},
          {"item()", ~r/scope|not allowed|not valid|not available/},
          {"accumulator()", ~r/scope|not allowed|not valid|not available/},
          {"state()", ~r/scope|not allowed|not valid|not available/},
          {"body_result()", ~r/scope|not allowed|not valid|not available/}
        ] do
      assert_raise CompileError, message, fn ->
        compile_fields(
          "decision value <- #{source}, do: {:ok, %{value: value}}\nexpander params, do: {:ok, params}"
        )
      end
    end
  end

  test "compilation, target lookup, and Flow validation do not run either body" do
    owner =
      compile_fields(
        """
        decision [] do
          send(:erlang.list_to_pid(@test_pid_text), :decision_work)
          {:ok, %{value: 1}}
        end
        expander params do
          send(:erlang.list_to_pid(@test_pid_text), :expander_work)
          {:ok, params}
        end
        """,
        before: ~s|@test_pid_text ~c"#{:erlang.pid_to_list(self())}"|
      )

    assert is_atom(target(owner, :decision))
    assert is_atom(target(owner, :expander))
    assert {:ok, _} = Jido.Flow.validate(owner.flow())
    assert {:ok, _} = Jido.Flow.validate_executable(owner.flow())
    assert {:ok, _} = Jido.Flow.compile(owner.flow())
    refute_received :decision_work
    refute_received :expander_work

    assert {:ok, %{value: 1}} = Jido.Exec.run(owner)
    assert_received :decision_work
    assert_received :expander_work
  end

  test "Spark still validates required Dispatch fields before wrapper emission" do
    owner = compile_fields("decision [], do: {:ok, %{}}\nexpander params, do: {:ok, params}")
    actions = [target(owner, :decision), target(owner, :expander)]
    signatures = Enum.map(actions, & &1.module_info(:md5))

    for fields <- [
          "decision [], name: \"replacement\", do: {:ok, %{}}",
          "expander params, name: \"replacement\", do: {:ok, params}"
        ] do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise Spark.Error.DslError, ~r/required/, fn ->
          compile_fields(fields, owner: owner)
        end
      end)

      assert Enum.map(actions, & &1.module_info(:md5)) == signatures
    end
  end

  test "ordinary inline Step, Choice, Map, Reduce, and Iterate roles still reject continuation" do
    action = "action [], do: {:continue, %{value: 3}, #{inspect(Echo)}}"

    for declaration <- [
          "step \"node\" do\n#{action}\nend",
          """
          choice "node" do
            option "selected" do
              condition true
              #{action}
            end
            otherwise action: #{inspect(Echo)}, params: %{}
          end
          """,
          """
          choice "node" do
            option "skipped", condition: false, action: #{inspect(Echo)}, params: %{}
            otherwise do
              #{action}
            end
          end
          """,
          "map \"node\" do\ncollection [1]\n#{action}\nend",
          "reduce \"node\" do\ncollection [1]\ninitial %{}\n#{action}\nend",
          "iterate \"node\" do\nstate [], initial: %{}\n#{action}\nrepeat 1\nend"
        ] do
      owner = compile_flow(declaration <> "\noutput %{value: result(\"node\")}")

      assert {:error, error} = Jido.Exec.run(owner)

      assert Exception.message(error) =~
               "action continuation is not allowed from this Flow position"
    end
  end

  defp compile_fields(fields, options \\ []) do
    compile_flow("dispatch \"next\" do\n#{fields}\nend\noutput result(\"next\")", options)
  end

  defp test_pid_attribute,
    do: ~s|@test_pid :erlang.list_to_pid(~c"#{:erlang.pid_to_list(self())}")|

  defp target(owner, role) do
    Jido.Action.Inline.target!(owner, host: Jido.Flow, dispatch: "next", role: role)
  end

  defp compile_flow(declarations, options \\ []) do
    owner =
      Keyword.get_lazy(options, :owner, fn ->
        Module.concat(__MODULE__, "Owner#{System.unique_integer([:positive])}")
      end)

    loaded = MapSet.new(:code.all_loaded(), &elem(&1, 0))

    try do
      source = """
      defmodule #{inspect(owner)} do
        use Jido.Flow, name: "dispatch_inline_test"
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
            {:ok, Code.compile_string(source, "dispatch_inline.ex")}
          rescue
            error -> {:error, error, __STACKTRACE__}
          end
        end)

      case Task.await(task, 30_000) do
        {:ok, _} -> owner
        {:error, error, stacktrace} -> reraise error, stacktrace
      end
    after
      owned =
        for {module, _} <- :code.all_loaded(),
            not MapSet.member?(loaded, module),
            String.starts_with?(Atom.to_string(module), [
              "Elixir.Jido.Flow.DSL.InlineDispatchActionTest.",
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
