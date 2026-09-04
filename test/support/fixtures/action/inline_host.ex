defmodule JidoActionTest.Fixtures.Action.InlineHost do
  @moduledoc false

  alias Jido.Action.Inline

  defmodule Field do
    @moduledoc false
    @enforce_keys [:key]
    defstruct [:key]
  end

  defmacro __using__(options) do
    Module.put_attribute(__CALLER__.module, :inline_host_mode, Keyword.fetch!(options, :mode))

    Module.put_attribute(
      __CALLER__.module,
      :inline_host_fields,
      Keyword.get(options, :fields, [])
    )

    Module.register_attribute(__CALLER__.module, :inline_host_sources, accumulate: true)

    quote do
      use Jido.Action.Inline
      import unquote(__MODULE__)
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro action(name, header, options) do
    declaration(name, header, options, __CALLER__)
  end

  defmacro action(name, header, options, body) do
    declaration(name, header, options ++ body, __CALLER__)
  end

  # This application helper must remain imported in bodies and private helpers.
  defmacro decorate(value) do
    quote do: "[" <> unquote(value) <> "]"
  end

  defmacro __before_compile__(env) do
    sources = env.module |> Module.get_attribute(:inline_host_sources) |> Map.new()
    mode = Module.get_attribute(env.module, :inline_host_mode)

    quote do
      def action_target(name) do
        Jido.Action.Inline.target!(__MODULE__, unquote(__MODULE__).path(name))
      end

      def action_source(name), do: Map.fetch!(unquote(Macro.escape(sources)), name)

      def action_params(name, fields) do
        unquote(__MODULE__).resolve(unquote(mode), action_source(name), fields)
      end
    end
  end

  def path(name), do: [host: __MODULE__, declaration: name, role: :action]

  def run(owner, name, input, context \\ %{}) do
    with {:ok, params} <- owner.action_params(name, input) do
      Jido.Exec.run(owner.action_target(name), params, context)
    end
  end

  def resolve(:callback, _source, params), do: {:ok, params}

  def resolve(:bound, source, fields) do
    Jido.Expr.evaluate(source,
      resolve: fn %Field{key: key} ->
        case Map.fetch(fields, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:missing_field, key}}
        end
      end
    )
  end

  defp declaration(name, header, options, caller) do
    parsed =
      case Module.get_attribute(caller.module, :inline_host_mode) do
        :bound -> Inline.parse_bound!(header, options, caller)
        :callback -> Inline.parse_callback!(header, options, caller)
      end

    # Validate host data before compile! can create an Action declaration.
    source = parse_source!(parsed, caller)
    declaration_name = Macro.unique_var(:declaration_name, __MODULE__)
    path = quote do: unquote(__MODULE__).path(unquote(declaration_name))

    compiled =
      Inline.compile!(path, parsed, caller,
        default_name: declaration_name,
        remove_imports: [{__MODULE__, [action: 3, action: 4]}]
      )

    quote do
      # Share the evaluated name between identity, metadata, and host data.
      unquote(declaration_name) = unquote(name)
      unquote(compiled.declaration_ast)
      @inline_host_sources {unquote(declaration_name), unquote(Macro.escape(source))}
      unquote(compiled.target_ast)
    end
  end

  defp parse_source!(%Inline{mode: :callback}, _caller), do: nil

  defp parse_source!(%Inline{params_ast: ast}, caller) do
    fields = Module.get_attribute(caller.module, :inline_host_fields)

    with {:ok, source} <- Jido.Expr.parse(ast, leaf_parser: &parse_field/1),
         :ok <-
           Jido.Expr.validate(source,
             validate_leaf: fn %Field{key: key} ->
               if key in fields, do: :ok, else: {:error, {:unknown_field, key}}
             end
           ) do
      source
    else
      {:error, error} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "invalid inline host source: #{inspect(error)}"
    end
  end

  defp parse_field({:field, _, [key]}) when is_atom(key), do: {:ok, %Field{key: key}}
  defp parse_field(_ast), do: :error
end
