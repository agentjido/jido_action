defmodule Jido.Flow.DSL.InlineStepCompiler do
  @moduledoc false

  alias Jido.Flow.Component
  alias Jido.Flow.DSL.{InlineStep, MacroSupport}

  @doc false
  @spec compile!(Macro.t(), InlineStep.t(), Macro.Env.t()) :: {String.t(), module(), Macro.t()}
  def compile!(name_ast, parsed, caller) do
    name = normalize_name!(name_ast, caller)
    {action, function} = identity(caller.module, name)
    create_action(action, function, name, caller)
    {name, action, owner_definition(function, parsed, caller)}
  end

  defp normalize_name!(name_ast, caller) do
    case Component.name(Macro.expand(name_ast, caller)) do
      {:ok, name} -> name
      {:error, error} -> MacroSupport.compile_error!(caller, Exception.message(error))
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
      def unquote(function)(unquote(parsed.pattern_ast), _context) do
        unquote_splicing(unimports)
        unquote(parsed.body_ast)
      end
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
