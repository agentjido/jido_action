defmodule Jido.Flow.DSL.InlineActionTest do
  use ExUnit.Case, async: false

  test "both Step forms use the shared owner and typed host path identity" do
    for declaration <- [
          ~s(step "increment", [], do: {:ok, %{value: 1}}),
          ~s(step "increment" do\n action [], do: {:ok, %{value: 1}}\nend)
        ] do
      owner = unique_owner()
      compile_source(owner, declaration)
      path = [host: Jido.Flow, step: "increment", role: :action]

      target = owner.step_action("increment")
      assert target == Jido.Action.Inline.target!(owner, path)
      assert target.__jido_inline_action__() == {owner, path}
      assert {:ok, %{value: 1}} = target.run(%{}, %{})
    end
  end

  test "a nested Step action uses the ordinary Action and Flow boundaries" do
    owner = unique_owner()

    compile_source(owner, """
    step "increment" do
      action value <- input(:value), context: ctx do
        {:ok, %{value: value + ctx.increment}}
      end
    end
    """)

    assert [%Jido.Flow.Step{name: "increment", action: target, params: params}] =
             owner.flow().components

    assert params == %{value: Jido.Flow.Ref.input(:value)}
    assert owner.step_action("increment") == target

    assert target.__jido_inline_action__() ==
             {owner, [host: Jido.Flow, step: "increment", role: :action]}

    assert Jido.Action.Inline.target!(owner, host: Jido.Flow, step: "increment", role: :action) ==
             target

    assert {:ok, %{value: 3}} = Jido.Exec.run(owner, %{value: 1}, %{increment: 2})
    assert {:ok, %{value: 7}} = Jido.Exec.run(target, %{value: 3}, %{increment: 4})
  end

  test "shorthand and nested Steps share the same target, metadata, data, and graph identity" do
    owner = unique_owner()

    compile_source(owner, """
    step "seed", [], do: {:ok, %{value: 2}}
    step "increment", value <- result("seed", :value), meta: %{tag: "same"} do
      {:ok, %{value: value + 1}}
    end
    """)

    target = owner.step_action("increment")
    canonical = owner.flow()
    identity = Jido.Flow.semantic_identity(canonical)
    dependencies = Jido.Flow.dependencies(canonical)

    quietly(fn ->
      compile_source(owner, """
      step "seed", [], do: {:ok, %{value: 2}}
      step "increment" do
        action value <- result("seed", :value) do
          {:ok, %{value: value + 1}}
        end
        meta %{tag: "same"}
      end
      """)
    end)

    assert owner.flow() == canonical
    assert Jido.Flow.semantic_identity(owner.flow()) == identity
    assert Jido.Flow.dependencies(owner.flow()) == dependencies
    assert target == owner.step_action("increment")
    assert target.name() == "increment"
    assert target.description() == nil
    assert target.schema() == []
    assert target.output_schema() == []
    assert target == generated_target(owner, "increment")
    assert {:ok, %{value: 3}} = Jido.Exec.run(owner)
  end

  test "bound headers support lists, sole maps, and no inputs" do
    for {header, body, params, result} <- [
          {"[left <- input(:value), right <- 2]", "{:ok, %{value: left + right}}",
           %{left: Jido.Flow.Ref.input(:value), right: 2}, %{value: 5}},
          {"%{value: value} <- input()", "{:ok, %{value: value}}", Jido.Flow.Ref.input([]),
           %{value: 3}},
          {"[]", "{:ok, %{value: 9}}", %{}, %{value: 9}}
        ] do
      owner = unique_owner()
      compile_source(owner, "step \"increment\" do\n action #{header}, do: #{body}\nend")
      assert [step] = owner.flow().components
      assert step.params == params
      assert {:ok, ^result} = Jido.Exec.run(owner, %{value: 3})
    end
  end

  test "binding sources use Expr operations and retain dependency discovery" do
    owner = unique_owner()

    compile_source(owner, """
    step "seed", [], do: {:ok, %{value: 2}}
    step "increment" do
      action [value <- input(:value) * 2 + result("seed", :value),
              allowed <- input(:enabled) and input(:value) > 0] do
        {:ok, %{value: value, allowed: allowed}}
      end
    end
    """)

    assert [_, %{params: %{value: %Jido.Expr{}, allowed: %Jido.Expr{}}}] = owner.flow().components
    assert {:ok, dependencies} = Jido.Flow.dependencies(owner.flow())
    assert dependencies["increment"].references == ["seed"]
    assert {:ok, %{value: 8, allowed: true}} = Jido.Exec.run(owner, %{value: 3, enabled: true})
  end

  test "invalid source expressions create no target and repair cleanly" do
    for header <- [
          "value <- String.length(input(:value))",
          "value <- ^external",
          "[value <- input(:value), other <- value + 1]"
        ] do
      owner = unique_owner()
      target = generated_target(owner, "increment")

      error =
        assert_raise CompileError,
                     ~r/inline Action binding source.*unsupported Flow expression/,
                     fn ->
                       compile_source(
                         owner,
                         "step \"increment\" do\n action #{header}, do: {:ok, %{}}\nend"
                       )
                     end

      assert error.file == "nested_inline.ex"
      assert error.line == 6
      refute Code.ensure_loaded?(target)

      compile_source(owner, "step \"increment\" do\n action [], do: {:ok, %{value: 1}}\nend")
      assert owner.step_action("increment") == target
      assert {:ok, %{value: 1}} = Jido.Exec.run(owner)
    end
  end

  test "legacy context bindings remain params while context options use the current callback" do
    owner = unique_owner()

    compile_source(owner, """
    step "legacy", ctx <- context(), do: {:ok, ctx}
    step "increment" do
      action ctx <- context(), context: current do
        {:ok, %{bound: ctx.token, current: current.token}}
      end
    end
    """)

    assert [legacy, nested] = owner.flow().components
    assert legacy.params == %{ctx: Jido.Flow.Ref.context()}
    assert nested.params == legacy.params
    assert nested.action.schema() == []

    assert {:ok, %{bound: :original, current: :original}} =
             Jido.Exec.run(owner, %{}, %{token: :original})

    assert {:ok, %{bound: :bound, current: :new}} =
             Jido.Exec.run(nested.action, %{ctx: %{token: :bound}}, %{token: :new})

    assert {:ok, %{token: :bound}} =
             Jido.Exec.run(legacy.action, %{ctx: %{token: :bound}}, %{token: :new})
  end

  test "Action metadata and schemas validate resolved params and output through Exec" do
    owner = unique_owner()

    compile_source(
      owner,
      """
      step "increment" do
        action value <- input(:value), name: @action_name, description: "Adds one",
          schema: Z.object(%{value: Z.integer()}), output_schema: Z.object(%{value: Z.integer()}), context: ctx do
          {:ok, %{value: if(ctx[:invalid_output], do: "bad", else: add_one(value))}}
        end
      end
      """,
      "alias Zoi, as: Z\n@action_name \"configured_action\"",
      "defp add_one(value), do: value + 1"
    )

    target = owner.step_action("increment")
    assert target.name() == "configured_action"
    assert target.description() == "Adds one"
    assert {:ok, %{value: 3}} = Jido.Exec.run(owner, %{value: 2})

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.Exec.run(target, %{value: "bad"})

    assert {:error, %Jido.Action.Error.InvalidInputError{}} =
             Jido.Exec.run(target, %{value: 2}, %{invalid_output: true})

    assert {:error, _} = Jido.Exec.run(owner, %{value: "bad"})
  end

  test "context and Action option errors retain shared validation" do
    for {options, message} <- [
          {"context: value", ~r/context variable collides/},
          {"context: _", ~r/context must be a named variable/},
          {"name: \"one\", name: \"two\"", ~r/duplicate inline Action option/},
          {"after: []", ~r/unsupported inline Action option/},
          {"schema: Zoi.integer()", ~r/schema|configuration/}
        ] do
      owner = unique_owner()

      assert_raise CompileError, message, fn ->
        compile_source(
          owner,
          "step \"increment\" do\n action value <- 1, #{options}, do: {:ok, %{value: value}}\nend"
        )
      end

      refute Code.ensure_loaded?(generated_target(owner, "increment"))
    end
  end

  test "all inline field conflicts leave an existing target unchanged in both orders" do
    inline = "action [], name: \"replacement\", do: {:ok, %{value: :replacement}}"
    explicit = "action JidoActionTest.Fixtures.Actions.Add"
    params = "params %{value: 1}"

    for fields <- [
          [inline, inline],
          [inline, explicit],
          [explicit, inline],
          [inline, params],
          [params, inline]
        ] do
      owner = unique_owner()

      compile_source(
        owner,
        "step \"increment\" do\n action [], do: {:ok, %{value: :original}}\nend"
      )

      target = owner.step_action("increment")
      original_beam = target.module_info(:md5)

      quietly(fn ->
        assert_raise CompileError,
                     ~r/inline Action conflicts with an existing (action|params) field/,
                     fn ->
                       compile_source(
                         owner,
                         "step \"increment\" do\n#{Enum.join(fields, "\n")}\nend",
                         "",
                         "",
                         true
                       )
                     end
      end)

      assert target.name() == "increment"
      assert target.module_info(:md5) == original_beam

      assert target.__jido_inline_action__() ==
               {owner, [host: Jido.Flow, step: "increment", role: :action]}
    end
  end

  test "invalid Action config does not replace an existing wrapper" do
    owner = unique_owner()

    compile_source(
      owner,
      "step \"increment\" do\n action [], do: {:ok, %{value: :original}}\nend"
    )

    target = owner.step_action("increment")
    original_beam = target.module_info(:md5)

    quietly(fn ->
      assert_raise CompileError, fn ->
        compile_source(
          owner,
          "step \"increment\" do\n action [], name: 123, do: {:ok, %{value: :replacement}}\nend",
          "",
          "",
          true
        )
      end
    end)

    assert target.name() == "increment"
    assert target.module_info(:md5) == original_beam
  end

  test "false declarations and false conflicting fields have no effect" do
    owner = unique_owner()

    compile_source(owner, """
    if false do
      step "increment" do
        action [], do: {:ok, %{value: :unused}}
      end
    end
    step "increment" do
      if false do
        params %{}
        action [], do: {:ok, %{value: :unused}}
      end
      action [], do: {:ok, %{value: :used}}
      if false, do: action(JidoActionTest.Fixtures.Actions.Add)
    end
    """)

    assert [step] = owner.flow().components
    assert step.name == "increment"
    assert map_size(owner.__jido_inline_actions__()) == 1
    assert {:ok, %{value: :used}} = Jido.Exec.run(owner)
  end

  test "sibling declarations keep names, lexical values, and scopes separate" do
    owner = unique_owner()

    compile_source(
      owner,
      """
      step @step_name do
        action [], do: {:ok, %{value: prefix(@step_name)}}
      end
      @step_name "increment"
      step @step_name do
        action [], do: {:ok, %{value: prefix(@step_name)}}
      end
      """,
      "@step_name \"first\"\nimport String, only: [upcase: 1]",
      """
      defp prefix(value), do: "name:" <> upcase(value)
      def scope_cleared?, do: unquote(is_nil(Module.get_attribute(__MODULE__, :__jido_flow_inline_scope__)))
      """
    )

    assert owner.scope_cleared?()
    assert owner.step_action("first") != owner.step_action("increment")
    assert {:ok, %{value: "name:FIRST"}} = owner.step_action("first").run(%{}, %{})
    assert {:ok, %{value: "name:INCREMENT"}} = Jido.Exec.run(owner)
  end

  test "Step names evaluate once at their declaration" do
    owner = unique_owner()

    compile_source(owner, """
    step (send(self(), :nested_name_evaluated); "increment") do
      action [], do: {:ok, %{value: 1}}
    end
    """)

    assert_received :nested_name_evaluated
    refute_received :nested_name_evaluated
    assert {:ok, %{value: 1}} = Jido.Exec.run(owner)
  end

  test "failed declaration evaluation restores the outer scope before repair" do
    owner = unique_owner()

    assert_raise CompileError, ~r/inline Action conflicts/, fn ->
      compile_source(
        owner,
        """
        try do
          step "increment" do
            action [], do: {:ok, %{}}
            params %{}
          end
        after
          send(@test_pid, {:scope_after_failure, Module.get_attribute(__MODULE__, :__jido_flow_inline_scope__)})
        end
        """,
        ~s|@test_pid :erlang.list_to_pid(~c"#{:erlang.pid_to_list(self())}")|,
        "",
        true
      )
    end

    assert_received {:scope_after_failure, nil}
    refute Code.ensure_loaded?(generated_target(owner, "increment"))

    compile_source(
      owner,
      "step \"increment\" do\n action [], do: {:ok, %{value: :repaired}}\nend"
    )

    assert {:ok, %{value: :repaired}} = Jido.Exec.run(owner)
  end

  test "inline fields outside a supported scope fail clearly" do
    for declarations <- [
          "action [], do: {:ok, %{}}",
          "step \"increment\" do\n action [], do: {:ok, %{}}\nend\naction [], do: {:ok, %{}}"
        ] do
      owner = unique_owner()

      assert_raise CompileError,
                   ~r/inline Action field requires a supported Flow declaration scope/,
                   fn ->
                     compile_source(owner, declarations)
                   end
    end
  end

  test "explicit Action and Flow module Steps keep their existing behavior" do
    child = unique_owner()
    compile_source(child, "step \"increment\" do\n action [], do: {:ok, %{value: 1}}\nend")
    owner = unique_owner()

    compile_source(owner, """
    step "child" do
      action #{inspect(child)}
      params %{}
    end
    step "increment" do
      action JidoActionTest.Fixtures.Actions.Add
      params %{value: result("child", :value)}
    end
    """)

    assert [%Jido.Flow.Subflow{}, %Jido.Flow.Step{}] = owner.flow().components
    assert owner.step_action("increment") == JidoActionTest.Fixtures.Actions.Add
    assert_raise ArgumentError, fn -> owner.step_action("child") end
    assert {:ok, %{value: 2}} = Jido.Exec.run(owner)
  end

  defp unique_owner,
    do: Module.concat(__MODULE__, "Owner#{System.unique_integer([:positive])}")

  defp compile_source(
         owner,
         declarations,
         before_code \\ "",
         after_code \\ "",
         isolated? \\ false
       ) do
    loaded = MapSet.new(:code.all_loaded(), &elem(&1, 0))

    try do
      source = """
      defmodule #{inspect(owner)} do
        use Jido.Flow, name: "nested_inline_test"
        #{before_code}
        flow do
          #{declarations}
          output result("increment")
        end
        #{after_code}
      end
      """

      compile = fn -> Code.compile_string(source, "nested_inline.ex") end
      if isolated?, do: isolated_compile(compile), else: compile.()
    after
      owned =
        for {module, _} <- :code.all_loaded(),
            not MapSet.member?(loaded, module),
            String.starts_with?(Atom.to_string(module), [
              "Elixir.Jido.Flow.DSL.InlineActionTest.",
              "Elixir.Jido.Action.Generated.Inline."
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

  defp generated_target(owner, name) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({owner, [host: Jido.Flow, step: name, role: :action]})
      )
      |> Base.encode16(case: :lower)

    Module.concat(Jido.Action.Generated.Inline, "A" <> digest)
  end

  defp quietly(fun), do: ExUnit.CaptureIO.capture_io(:stderr, fun)

  defp isolated_compile(compile) do
    # Spark does not clean its authoring process after a field raises. Normal
    # Mix rebuilds use a new compiler process. Do not alter Spark's private state.
    task =
      Task.async(fn ->
        try do
          {:ok, compile.()}
        rescue
          error -> {:error, error, __STACKTRACE__}
        end
      end)

    case Task.await(task, 30_000) do
      {:ok, result} -> result
      {:error, error, stacktrace} -> reraise error, stacktrace
    end
  end
end
