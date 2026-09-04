defmodule Jido.Flow.DSL.InlineStepCompiler do
  @moduledoc false

  alias Jido.Flow.Component
  alias Jido.Flow.DSL.{InlineStep, MacroSupport, ModuleCompiler}

  @doc false
  @spec compile!(Macro.t(), InlineStep.t(), Macro.Env.t()) :: {String.t(), module(), Macro.t()}
  def compile!(name_ast, parsed, caller) do
    name =
      case Component.name(Macro.expand(name_ast, caller)) do
        {:ok, name} -> name
        {:error, error} -> MacroSupport.compile_error!(caller, Exception.message(error))
      end

    {action, function} = identity(caller.module, name)
    definition = owner_definition(function, parsed, caller)

    # Run compiler mutations at declaration evaluation, not macro expansion.
    # This preserves source order and does not register untaken authoring branches.
    quoted =
      quote line: caller.line do
        unquote(__MODULE__).create!(unquote(name), unquote(action), unquote(function), __ENV__)
        unquote(definition)
      end

    {name, action, quoted}
  end

  @doc false
  @spec create!(String.t(), module(), atom(), Macro.Env.t()) :: term()
  def create!(name, action, function, caller) do
    ModuleCompiler.register_step!(name, caller)
    ModuleCompiler.reserve_function!(caller, {function, 2})
    ensure_owner!(action, name, caller)
    create_action(action, function, name, caller)
  end

  defp ensure_owner!(action, name, caller) do
    if Code.ensure_loaded?(action) and
         not (function_exported?(action, :__jido_inline_step__, 0) and
                action.__jido_inline_step__() == {caller.module, name}) do
      MacroSupport.compile_error!(
        caller,
        "generated inline Step module #{inspect(action)} already belongs to another definition"
      )
    end
  end

  defp identity(owner, name) do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({owner, name}))
      |> Base.encode16(case: :lower)

    {Module.concat(Jido.Flow.Generated.InlineStep, "A" <> digest),
     String.to_atom("__jido_inline_step_" <> digest)}
  end

  defp create_action(action, function, name, caller) do
    owner = caller.module

    definition =
      quote generated: true do
        @moduledoc false
        @compile {:no_warn_undefined, unquote(owner)}
        use Jido.Action, name: unquote(name), schema: [], output_schema: []

        @doc false
        def __jido_inline_step__, do: {unquote(owner), unquote(name)}

        @impl Jido.Action
        def run(params, context), do: unquote(owner).unquote(function)(params, context)
      end

    # Keep the source compiler's trackers, but do not import the owner's DSL or
    # application aliases into the self-contained Action wrapper.
    env = %{
      __ENV__
      | file: caller.file,
        line: caller.line,
        aliases: [],
        lexical_tracker: caller.lexical_tracker,
        tracers: caller.tracers
    }

    Module.create(action, definition, env)
  end

  defp owner_definition(function, parsed, caller) do
    unimports = declaration_unimports(caller)

    # Do not mark this definition as generated: the pattern and body must keep
    # the caller's diagnostics, lexical expansion, and original source lines.
    quote line: caller.line do
      @doc false
      @__jido_flow_generated_definition__ {unquote(function), 2}
      def unquote(function)(unquote(parsed.pattern_ast), _context) do
        unquote_splicing(unimports)
        unquote(parsed.body_ast)
      end

      Module.delete_attribute(__MODULE__, :__jido_flow_generated_definition__)
    end
  end

  defp declaration_unimports(caller) do
    (Keyword.keys(caller.functions) ++ Keyword.keys(caller.macros))
    |> Enum.uniq()
    |> Enum.filter(fn module ->
      name = Atom.to_string(module)
      String.starts_with?(name, ["Elixir.Jido.Flow.DSL", "Elixir.Spark.Dsl"])
    end)
    |> Enum.map(fn module ->
      quote generated: true do
        import unquote(module), only: []
      end
    end)
  end
end
