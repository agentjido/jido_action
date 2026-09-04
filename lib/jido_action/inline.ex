defmodule Jido.Action.Inline do
  @moduledoc """
  Compile-time inline Action support for host DSLs.

  Call `use Jido.Action.Inline` in each owner module. A host macro then:

  1. Calls `parse_bound!/3` or `parse_callback!/3` for the slot's input mode.
  2. Parses and validates `params_ast` with its own expression adapter in bound mode.
  3. Calls `compile!/4` and emits `declaration_ast` at the declaration site.
  4. Uses `target_ast` after that declaration AST to store an ordinary Action target.

  For example, a host can use the path
  `[host: MyApp.DSL, declaration: "greet", role: :action]`. It can later call
  `target!(Owner, path)` to retrieve only the target, without the source mapping.
  Nested declarations add typed segments, such as `choice: "route"` and
  `option: "otherwise"`. An option and a fallback must have different paths.

  Paths and Action metadata are separate. The host supplies a default metadata
  name; a declaration can override it with `name:`. Generated module names are
  implementation details, not public names or code versions.

  Bodies keep the owner's lexical scope and private helpers. Deploy the owner
  and generated Action BEAM files together. Lookup is available only after the
  owner compiles. It does not execute work or create atoms. Do not pass runtime
  or stored code to the compile-time APIs.
  """

  alias Jido.Action.Inline.{Compiler, Owner, Parser}

  @enforce_keys [:mode, :params_ast, :pattern_ast, :body_ast, :options, :context_ast]
  defstruct @enforce_keys

  @typedoc "The input contract selected by the host slot."
  @type mode :: :bound | :callback

  @typedoc "A typed host identity. It starts with `:host` and ends with `:role`."
  @type path :: [{atom(), atom() | String.t() | integer()}]

  @typedoc "Parsed compile-time code. `params_ast` is nil only in callback mode."
  @type t :: %__MODULE__{
          mode: mode(),
          params_ast: Macro.t() | nil,
          pattern_ast: Macro.t(),
          body_ast: Macro.t(),
          options: keyword(Macro.t()),
          context_ast: Macro.t() | nil
        }

  @typedoc "AST returned to a host. Emit the declaration before using the target."
  @type compilation :: %{target_ast: Macro.t(), declaration_ast: Macro.t()}

  @typedoc "Declaration-only imports to remove from the body, by module and exact arity."
  @type remove_imports :: [{module(), [{atom(), non_neg_integer()}]}]

  @doc "Installs owner hooks. Repeated use preserves declarations and host hooks."
  defmacro __using__(_options) do
    quote do
      Jido.Action.Inline.setup!(__ENV__)
    end
  end

  @doc "Installs owner hooks during module construction. Usually called through `use`."
  @spec setup!(Macro.Env.t()) :: :ok
  def setup!(caller), do: Owner.setup!(caller)

  @doc """
  Parses named bindings, a binding list, a sole map binding, or `[]`.

  Options are `do:`, `name:`, `description:`, `schema:`, `output_schema:`, and
  `context: named_variable`. Schemas are not inferred from patterns. This only
  checks header shape; the host must validate the returned source AST before
  calling `compile!/4`. It does not expand or evaluate source calls.

  Raises `CompileError` for an invalid header or option, at the source location.
  """
  @spec parse_bound!(Macro.t(), keyword(), Macro.Env.t()) :: t()
  def parse_bound!(bindings, options, caller), do: Parser.bound!(bindings, options, caller)

  @doc """
  Parses a named parameter variable or a map pattern for direct callback input.

  Accepts the same options as `parse_bound!/3`, but rejects source bindings.
  The generated callback receives its parameters unchanged and has no host
  parameter mapping. Raises `CompileError` for invalid headers or options.
  """
  @spec parse_callback!(Macro.t(), keyword(), Macro.Env.t()) :: t()
  def parse_callback!(pattern, options, caller), do: Parser.callback!(pattern, options, caller)

  @doc """
  Builds declaration and target AST inside a compiling owner module.

  `path_ast` must evaluate to a typed path with a host namespace, one or more
  declaration segments, and a final role. Each segment is an atom key paired
  with a non-nil atom, string, or integer. The path is evaluated once, when the
  emitted declaration executes. A false compile-time branch creates no target.

  Options:

  - `default_name:` is metadata AST used when the parsed options omit `name:`.
    Supply it unless the declaration has an explicit name.
  - `remove_imports:` lists exact declaration-only imports to remove from the
    body. Other imports remain available. The default is `[]`.

  Metadata and schemas evaluate in the owner at the declaration site, under
  normal Action configuration and static-schema rules. `context:` binds the
  actual callback context without changing parameters or schemas.

  Raises `CompileError` for invalid configuration, paths, duplicate identities,
  reserved owner functions, or calls outside a compiling owner. The returned
  AST is a compile-time implementation detail; it is not a runtime model.
  """
  @spec compile!(Macro.t(), t(), Macro.Env.t(), keyword()) :: compilation()
  def compile!(path_ast, %__MODULE__{} = parsed, caller, options) do
    Parser.options!(options, [:default_name, :remove_imports], caller, "compiler")
    Compiler.compile!(path_ast, parsed, caller, options)
  end

  @doc "Compiles a declaration with an explicit `name:` and no compiler options. See `compile!/4`."
  @spec compile!(Macro.t(), t(), Macro.Env.t()) :: compilation()
  def compile!(path_ast, parsed, caller), do: compile!(path_ast, parsed, caller, [])

  @doc """
  Returns the compiled Action for the owner's exact typed path.

  Raises `ArgumentError` for an invalid or unknown path, an owner without inline
  targets, or an owner that is still compiling. Lookup does not create atoms,
  compile code, execute a body, or return the original source mapping.
  """
  @spec target!(module(), path()) :: module()
  def target!(owner, path), do: Owner.target!(owner, path)
end
