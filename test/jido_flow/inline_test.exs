defmodule Jido.Flow.InlineTest.Host do
  @moduledoc false

  defmacro __using__(_options) do
    quote do
      use Jido.Flow.Inline
      import Jido.Flow.InlineTest.Host, only: [define: 3]
    end
  end

  defmacro define(path, options, do: body) do
    compiled = Jido.Flow.Inline.compile!(path, options, body, __CALLER__)

    quote do
      unquote(compiled.declaration_ast)
      unquote(compiled.target_ast)
    end
  end
end

defmodule Jido.Flow.InlineTest.LateHook do
  @moduledoc false

  defmacro __before_compile__(_caller) do
    quote do
      @late_target (define([host: Jido.Flow.InlineTest.Host, declaration: "late", role: :flow],
                      name: "late_inline_flow"
                    ) do
                      step "increment",
                        action: JidoActionTest.Fixtures.Actions.Add,
                        params: %{value: input(:value), amount: 1}

                      output result("increment")
                    end)

      def late_target, do: @late_target
    end
  end
end

defmodule Jido.Flow.InlineTest.LateOwner do
  @moduledoc false
  use Jido.Flow.InlineTest.Host
  @before_compile Jido.Flow.InlineTest.LateHook
end

defmodule Jido.Flow.InlineTest.Extension do
  @moduledoc false
  use Jido.Flow.Extension

  defmacro add(name, value, amount) do
    quote do
      step unquote(name),
        action: JidoActionTest.Fixtures.Actions.Add,
        params: %{value: unquote(value), amount: unquote(amount)}
    end
  end
end

defmodule Jido.Flow.InlineTest.Owner do
  @moduledoc false
  require Jido.Flow.InlineTest.Host

  @path [host: Jido.Flow.InlineTest.Host, declaration: "math", role: :flow]

  @target (Jido.Flow.InlineTest.Host.define @path,
             id: "tests/flows/inline-math",
             name: "inline_math",
             description: "An embedded math Flow",
             extensions: [Jido.Flow.InlineTest.Extension] do
             add("increment", input(:value), 1)

             step "double", value <- result("increment", :value) do
               {:ok, %{value: value * 2}}
             end

             output result("double")
           end)

  def path, do: @path
  def target, do: @target
end

defmodule Jido.Flow.InlineTest do
  use ExUnit.Case, async: false

  alias Jido.Flow.Inline
  alias Jido.Flow.InlineTest.{LateOwner, Owner}

  test "a host compiles an embedded body as one normal Flow module" do
    target = Owner.target()

    assert target == Inline.target!(Owner, Owner.path())
    assert target.__jido_inline_flow__() == {Owner, Owner.path()}
    assert target.__jido_authoring_kind__() == :flow
    assert target.name() == "inline_math"
    assert target.description() == "An embedded math Flow"
    assert target.flow().name == "inline_math"
    assert {:ok, %{value: 8}} = Jido.Exec.run(target, %{value: 3})

    assert action = target.step_action("double")
    assert action.__jido_authoring_kind__() == :action
  end

  test "the owner rejects a duplicate inline Flow identity" do
    owner = unique_owner("Duplicate")
    path = [host: Jido.Flow.InlineTest.Host, declaration: "same", role: :flow]

    source = """
    defmodule #{inspect(owner)} do
      require Jido.Flow.InlineTest.Host

      Jido.Flow.InlineTest.Host.define #{inspect(path)}, [name: "first"] do
        step "first",
          action: JidoActionTest.Fixtures.Actions.Add,
          params: %{value: 1, amount: 1}

        output result("first")
      end

      Jido.Flow.InlineTest.Host.define #{inspect(path)}, [name: "second"] do
        step "second",
          action: JidoActionTest.Fixtures.Actions.Add,
          params: %{value: 1, amount: 1}

        output result("second")
      end
    end
    """

    assert_raise CompileError, ~r/duplicate inline Flow identity/, fn ->
      Code.compile_string(source, "duplicate_inline_flow.ex")
    end

    purge([owner, generated_target(owner, path)])
  end

  test "an owner index includes a Flow emitted by a late compile hook" do
    path = [host: Jido.Flow.InlineTest.Host, declaration: "late", role: :flow]

    assert LateOwner.late_target() == Inline.target!(LateOwner, path)
    assert {:ok, %{value: 4}} = Jido.Exec.run(LateOwner.late_target(), %{value: 3})
  end

  test "the normal Flow compiler reports an invalid embedded body at its source" do
    owner = unique_owner("Invalid")
    path = [host: Jido.Flow.InlineTest.Host, declaration: "invalid", role: :flow]

    source = """
    defmodule #{inspect(owner)} do
      require Jido.Flow.InlineTest.Host

      Jido.Flow.InlineTest.Host.define #{inspect(path)}, [name: "invalid"] do
        step "increment",
          action: JidoActionTest.Fixtures.Actions.Add,
          params: %{value: input(:value), amount: 1}

        output result("missing")
      end
    end
    """

    error =
      assert_raise CompileError, ~r/reference points to an unknown component/, fn ->
        Code.compile_string(source, "invalid_inline_flow.ex")
      end

    assert error.file == "invalid_inline_flow.ex"
    purge([owner, generated_target(owner, path)])
  end

  test "lookup rejects an unknown or malformed identity" do
    assert_raise ArgumentError, ~r/unknown inline Flow identity/, fn ->
      Inline.target!(Owner, host: Jido.Flow.InlineTest.Host, declaration: "missing", role: :flow)
    end

    assert_raise ArgumentError, ~r/unknown inline Flow identity/, fn ->
      Inline.target!(Owner, host: Jido.Flow.InlineTest.Host, declaration: "math", role: :action)
    end
  end

  defp unique_owner(label) do
    Module.concat(__MODULE__, "#{label}#{System.unique_integer([:positive])}")
  end

  defp generated_target(owner, path) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({owner, path}))
      |> Base.encode16(case: :lower)

    Module.concat(Jido.Flow.Generated.Inline, "F" <> digest)
  end

  defp purge(modules) do
    for module <- modules do
      :code.purge(module)
      :code.delete(module)
    end
  end
end
