defmodule Jido.Flow.DSL.InlineStepCompiler do
  @moduledoc false

  alias Jido.Action.Inline
  alias Jido.Flow.DSL.{InlineAction, ModuleCompiler}

  @doc false
  @spec compile!(Macro.t(), Inline.t(), Macro.Env.t()) :: {Macro.t(), Macro.t(), Macro.t()}
  def compile!(name_ast, parsed, caller) do
    name = Macro.unique_var(:step_name, __MODULE__)
    parsed = %{parsed | options: []}
    compiled = compile_action!(name, parsed, caller, [])

    declaration =
      quote line: caller.line do
        unquote(name) = unquote(ModuleCompiler).register_step!(unquote(name_ast), __ENV__)
        unquote(compiled.declaration_ast)
      end

    {name, compiled.target_ast, declaration}
  end

  @doc false
  @spec compile_action!(Macro.t(), Inline.t(), Macro.Env.t(), keyword()) :: Inline.compilation()
  def compile_action!(name, parsed, caller, options) do
    path = quote do: [{:host, Jido.Flow}, {:step, unquote(name)}, {:role, :action}]

    Inline.Compiler.compile!(
      path,
      parsed,
      caller,
      [
        default_name: name,
        identity: {__MODULE__, :identity},
        reserved_label: "Flow",
        module_label: "inline Step",
        remove_imports: InlineAction.declaration_imports(caller)
      ] ++ options
    )
  end

  @doc false
  @spec identity(module(), Inline.path()) :: {module(), atom(), atom(), term()}
  def identity(owner, [{:host, Jido.Flow}, {:step, name}, {:role, :action}]) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({owner, name})) |> Base.encode16(case: :lower)

    {Module.concat(Jido.Flow.Generated.InlineStep, "A" <> digest),
     String.to_atom("__jido_inline_step_" <> digest), :__jido_inline_step__, {owner, name}}
  end
end
