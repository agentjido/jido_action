defmodule Jido.Flow.DSL.InlineStepCompiler do
  @moduledoc false

  alias Jido.Flow.DSL.{InlineStep, MacroSupport, ModuleCompiler}

  @doc false
  @spec compile!(Macro.t(), InlineStep.t(), Macro.Env.t()) :: {Macro.t(), Macro.t(), Macro.t()}
  def compile!(name_ast, parsed, caller) do
    name = Macro.unique_var(:step_name, __MODULE__)
    action = Macro.unique_var(:step_action, __MODULE__)
    function = Macro.unique_var(:step_function, __MODULE__)
    definition = owner_definition(function, parsed, caller)

    # Resolve names and create targets at declaration evaluation. Attribute reads
    # then see preceding declarations, and each name expression runs only once.
    quoted =
      quote line: caller.line do
        {unquote(name), unquote(action), unquote(function)} =
          unquote(__MODULE__).create!(unquote(name_ast), __ENV__)

        unquote(definition)
      end

    {name, action, quoted}
  end

  @doc false
  @spec create!(term(), Macro.Env.t()) :: {String.t(), module(), atom()}
  def create!(value, caller) do
    name = ModuleCompiler.register_step!(value, caller)
    {action, function} = identity(caller.module, name)
    ModuleCompiler.reserve_function!(caller, {function, 2})
    ensure_owner!(action, name, caller)
    create_action(action, function, name, caller)
    {name, action, function}
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
    # Keep this unquote for def to resolve the declaration-time function name.
    function_name = {:unquote, [], [function]}

    # Do not mark this definition as generated: the pattern and body must keep
    # the caller's diagnostics, lexical expansion, and original source lines.
    quote line: caller.line do
      @doc false
      @__jido_flow_generated_definition__ {unquote(function), 2}
      def unquote(function_name)(unquote(parsed.pattern_ast), _context) do
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

      module in [Jido.Flow.DSL, Spark.Dsl] or
        String.starts_with?(name, ["Elixir.Jido.Flow.DSL.", "Elixir.Spark.Dsl."])
    end)
    |> Enum.map(fn module ->
      quote generated: true do
        import unquote(module), only: []
      end
    end)
  end
end
