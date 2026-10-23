defmodule Jido.Flow.Inline do
  @moduledoc """
  Compiles an embedded Flow declaration for another module DSL.

  This module is for compile-time host DSLs. A host should call
  `use Jido.Flow.Inline` in each owner. It creates a normal `Jido.Flow` module
  from standard Flow options and a standard `flow do` body. The host stores the
  returned target as it would store any other Flow module.

  A host macro must emit `declaration_ast` before it uses `target_ast`:

      defmacro operation(path, options, do: body) do
        compiled =
          Jido.Flow.Inline.compile!(path, options, body, __CALLER__)

        quote do
          unquote(compiled.declaration_ast)
          unquote(compiled.target_ast)
        end
      end

  `path` is a compile-time identity owned by the host. It must start with a
  `:host` segment and end with `role: :flow`. The generated module name is an
  implementation detail. Deploy the owner and generated Flow BEAM files
  together.

  The embedded body uses the normal Flow compiler. It does not add a new Flow
  type, execution path, or serialization format. An inline Flow has its own
  module scope. Put reusable code in Actions or Flow extensions, not in private
  functions of the host module.
  """

  alias Jido.Flow.Inline.{Compiler, Owner}

  @typedoc "A typed host identity that starts with `:host` and ends with `role: :flow`."
  @type path :: [{atom(), atom() | String.t() | integer()}]

  @typedoc "AST returned to a host. Emit the declaration before using the target."
  @type compilation :: %{target_ast: Macro.t(), declaration_ast: Macro.t()}

  @doc "Installs owner lookup and compile hooks. Repeated use preserves declarations."
  defmacro __using__(_options) do
    quote do
      Jido.Flow.Inline.setup!(__ENV__)
    end
  end

  @doc "Installs owner hooks during module construction. Usually called through `use`."
  @spec setup!(Macro.Env.t()) :: :ok
  def setup!(caller), do: Owner.setup!(caller)

  @doc """
  Compiles one embedded Flow declaration.

  `options_ast` accepts the same options as `use Jido.Flow`, including Flow
  extensions. `body_ast` is the contents of a normal `flow do` block. The path,
  options, and body are compile-time source. Do not pass runtime or stored code.

  Raises `CompileError` for an invalid owner, identity, Flow option, or Flow
  body.
  """
  @spec compile!(Macro.t(), Macro.t(), Macro.t(), Macro.Env.t()) :: compilation()
  def compile!(path_ast, options_ast, body_ast, caller) do
    Compiler.compile!(path_ast, options_ast, body_ast, caller)
  end

  @doc """
  Returns the generated Flow module for an owner's exact typed path.

  Lookup is available only after the owner compiles. It does not compile or run
  the Flow.
  """
  @spec target!(module(), path()) :: module()
  def target!(owner, path), do: Owner.target!(owner, path)
end
