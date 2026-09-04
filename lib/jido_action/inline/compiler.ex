defmodule Jido.Action.Inline.Compiler do
  @moduledoc false

  alias Jido.Action.Inline.{Owner, Parser}

  @doc false
  @spec compile!(Macro.t(), Jido.Action.Inline.t(), Macro.Env.t(), keyword()) ::
          Jido.Action.Inline.compilation()
  def compile!(path_ast, parsed, caller, options) do
    Owner.ensure_compiling!(caller)
    target = Macro.unique_var(:inline_action, __MODULE__)
    function = Macro.unique_var(:inline_function, __MODULE__)
    config = Keyword.put_new(parsed.options, :name, Keyword.get(options, :default_name))
    definition = owner_definition(function, parsed, caller, options)
    identity = Keyword.get(options, :identity)

    declaration =
      quote line: caller.line do
        {unquote(target), unquote(function)} =
          unquote(__MODULE__).create!(
            unquote(path_ast),
            unquote(config),
            __ENV__,
            unquote(Macro.escape(identity))
          )

        unquote(definition)
      end

    %{target_ast: target, declaration_ast: declaration}
  end

  @doc false
  @spec create!(term(), keyword(), Macro.Env.t(), {module(), atom()} | nil) :: {module(), atom()}
  def create!(path, config, caller, identity_override) do
    Owner.setup!(caller)
    path = Owner.validate_path!(path, caller)
    Owner.check_identity!(path, caller)
    {config, _schema, _output_schema} = Jido.Action.__prepare_config__!(config, caller)
    {target, function, marker, value} = identity(caller.module, path, identity_override)
    Owner.reserve_function!(caller, {function, 2})
    ensure_owner!(target, marker, value, caller)
    create_action(target, function, marker, value, config, caller)
    Owner.register!(path, target, caller)
    {target, function}
  end

  defp identity(owner, path, nil) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({owner, path})) |> Base.encode16(case: :lower)

    {Module.concat(Jido.Action.Generated.Inline, "A" <> digest),
     String.to_atom("__jido_inline_action_" <> digest), :__jido_inline_action__, {owner, path}}
  end

  # Only internal adapters may retain an existing target recipe and marker.
  defp identity(owner, path, {module, function}), do: apply(module, function, [owner, path])

  defp ensure_owner!(target, marker, value, caller) do
    if Code.ensure_loaded?(target) and
         not (function_exported?(target, marker, 0) and apply(target, marker, []) == value) do
      Parser.error!(
        nil,
        caller,
        "generated inline Action module #{inspect(target)} already belongs to another definition"
      )
    end
  end

  defp create_action(target, function, marker, value, config, caller) do
    owner = caller.module

    definition =
      quote generated: true do
        @moduledoc false
        @compile {:no_warn_undefined, unquote(owner)}
        use Jido.Action, unquote(Macro.escape(config))

        @doc false
        def unquote(marker)(), do: unquote(Macro.escape(value))

        @impl Jido.Action
        def run(params, context), do: unquote(owner).unquote(function)(params, context)
      end

    env = %{
      __ENV__
      | file: caller.file,
        line: caller.line,
        aliases: [],
        lexical_tracker: caller.lexical_tracker,
        tracers: caller.tracers
    }

    Module.create(target, definition, env)
  end

  defp owner_definition(function, parsed, caller, options) do
    unimports = declaration_unimports(Keyword.get(options, :remove_imports, []), caller)
    function_name = {:unquote, [], [function]}
    context = parsed.context_ast || Macro.var(:_context, __MODULE__)

    quote line: caller.line do
      @doc false
      @__jido_inline_generated__ {unquote(function), 2}
      def unquote(function_name)(unquote(parsed.pattern_ast), unquote(context)) do
        unquote_splicing(unimports)
        unquote(parsed.body_ast)
      end

      Module.delete_attribute(__MODULE__, :__jido_inline_generated__)
    end
  end

  defp declaration_unimports(removals, caller) do
    unless valid_removals?(removals) do
      Parser.error!(
        nil,
        caller,
        "inline Action remove_imports must be a list of {module, [{name, arity}]} entries"
      )
    end

    removals
    |> Enum.reduce([], fn {module, removed}, acc ->
      Keyword.update(acc, module, removed, &(&1 ++ removed))
    end)
    |> Enum.map(fn {module, removed} ->
      remaining =
        (Keyword.get(caller.functions, module, []) ++ Keyword.get(caller.macros, module, []))
        |> Enum.uniq()
        |> Enum.reject(&(&1 in removed))

      quote generated: true do
        import unquote(module), only: unquote(remaining)
      end
    end)
  end

  defp valid_removals?([]), do: true

  defp valid_removals?([{module, imports} | rest]) when is_atom(module) and not is_nil(module),
    do: valid_imports?(imports) and valid_removals?(rest)

  defp valid_removals?(_), do: false

  defp valid_imports?([]), do: true

  defp valid_imports?([{name, arity} | rest])
       when is_atom(name) and is_integer(arity) and arity >= 0,
       do: valid_imports?(rest)

  defp valid_imports?(_), do: false
end
