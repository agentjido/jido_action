defmodule Jido.Flow.DSL.InlineAction do
  @moduledoc false

  alias Jido.Action.Inline
  alias Jido.Flow.DSL.{Expression, InlineStepCompiler, MacroSupport}

  @scope :__jido_flow_inline_scope__
  @step_options Jido.Flow.DSL.Extension.Flow.Step.Options
  @field_adapters [
    Jido.Flow.DSL.InlineAction.Step,
    Jido.Flow.DSL.InlineAction.Map,
    Jido.Flow.DSL.InlineAction.Reduce,
    Jido.Flow.DSL.InlineAction.Choice,
    Jido.Flow.DSL.InlineAction.Choice.Option,
    Jido.Flow.DSL.InlineAction.Choice.Otherwise,
    Jido.Flow.DSL.InlineAction.Iterate,
    Jido.Flow.DSL.InlineAction.Iterate.State
  ]

  defmacro action(value), do: field(:action, value, __CALLER__, @step_options, "Step")
  defmacro params(value), do: field(:params, value, __CALLER__, @step_options, "Step")

  defmacro action(bindings, options),
    do: bound(bindings, options, __CALLER__, @step_options, "Step")

  defmacro action(bindings, options, body_options) do
    bound_options(bindings, options, body_options, __CALLER__, @step_options, "Step")
  end

  @doc false
  @spec bound_options(Macro.t(), keyword(), keyword(), Macro.Env.t(), module() | nil, String.t()) ::
          Macro.t()
  def bound_options(bindings, options, body_options, caller, setter, label) do
    Inline.Parser.options!(
      options,
      [:name, :description, :schema, :output_schema, :context],
      caller
    )

    Inline.Parser.options!(body_options, [:do], caller)
    bound(bindings, options ++ body_options, caller, setter, label)
  end

  @doc false
  @spec bound(Macro.t(), keyword(), Macro.Env.t(), module() | nil, String.t()) :: Macro.t()
  def bound(_bindings, _options, caller, nil, label),
    do: MacroSupport.compile_error!(caller, "#{label} does not accept an inline Action field")

  def bound(bindings, options, caller, setter, label) do
    parsed = parse_bound!(bindings, options, caller, label)
    validate_sources!(bindings, caller, "inline Action")
    path = Macro.unique_var(:inline_action_path, __MODULE__)
    compiled = compile_bound(setter, path, parsed, caller)

    quote line: caller.line do
      unquote(path) = unquote(__MODULE__).claim_inline!(__ENV__, :action, :params)
      unquote(compiled.declaration_ast)
      require unquote(setter)
      unquote(setter).action(unquote(compiled.target_ast))
      unquote(setter).params(unquote(parsed.params_ast))
    end
  end

  defp parse_bound!(bindings, options, caller, "Step"),
    do: Inline.parse_bound!(bindings, options, caller)

  defp parse_bound!(bindings, options, caller, label) do
    Inline.parse_bound!(bindings, options, caller)
  rescue
    error in CompileError ->
      reraise %{error | description: "#{label} action: #{error.description}"}, __STACKTRACE__
  end

  defp compile_bound(@step_options, path, parsed, caller) do
    name = quote do: Keyword.fetch!(unquote(path), :step)
    InlineStepCompiler.compile_action!(name, parsed, caller, emit: {__MODULE__, :defer!})
  end

  defp compile_bound(_setter, path, parsed, caller) do
    Inline.Compiler.compile!(path, parsed, caller,
      default_name: quote(do: unquote(__MODULE__).default_name(unquote(path))),
      remove_imports: declaration_imports(caller),
      emit: {__MODULE__, :defer!}
    )
  end

  @doc false
  @spec default_name(Inline.path()) :: String.t()
  def default_name(path) do
    case Enum.at(path, -2) do
      {:fallback, :otherwise} -> "otherwise"
      {_kind, name} -> name
    end
  end

  @doc false
  @spec field(atom(), Macro.t(), Macro.Env.t(), module() | nil, String.t()) :: Macro.t()
  def field(_field, _value, caller, nil, label),
    do: MacroSupport.compile_error!(caller, "#{label} does not accept an inline Action field")

  def field(field, value, caller, setter, _label) do
    quote line: caller.line do
      unquote(__MODULE__).claim_field!(__ENV__, unquote(field))
      require unquote(setter)
      unquote(setter).unquote(field)(unquote(value))
    end
  end

  @doc false
  @spec fields(Macro.t(), module()) :: Macro.t()
  def fields(block, module) do
    setter = Module.concat(module, Options)
    segments = module |> Module.split() |> Enum.drop(5)
    adapter = Module.concat([__MODULE__ | segments])

    unimports =
      for module <- [__MODULE__ | @field_adapters] do
        quote do
          import unquote(module), only: []
        end
      end

    setter_import =
      unless module in [
               Jido.Flow.DSL.Extension.Flow.Choice,
               Jido.Flow.DSL.Extension.Flow.Iterate.State
             ] do
        quote do
          import unquote(setter), except: [action: 1, params: 1]
        end
      end

    quote do
      unquote_splicing(unimports)
      unquote(setter_import)
      import unquote(adapter)
      unquote(block)
    end
  end

  @doc false
  @spec validate_sources!(Macro.t(), Macro.Env.t(), String.t()) :: :ok
  def validate_sources!(bindings, caller, label) do
    for {:<-, _, [_pattern, source]} <- List.wrap(bindings) do
      validate_source!(source, caller, label)
    end

    :ok
  end

  defp validate_source!(source, caller, label) do
    case Expression.parse(source) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        line =
          case source do
            {_, metadata, _} -> Keyword.get(metadata, :line, caller.line)
            _ -> caller.line
          end

        MacroSupport.compile_error!(
          %{caller | line: line},
          "#{label} binding source: #{error.message}"
        )
    end
  end

  @doc false
  @spec scoped(Macro.t(), atom(), Macro.t(), Macro.Env.t()) :: Macro.t()
  def scoped(name, kind, declaration, caller) do
    previous = Macro.unique_var(:previous_inline_scope, __MODULE__)

    quote line: caller.line do
      unquote(previous) = unquote(__MODULE__).enter!(__ENV__, unquote(kind), unquote(name))

      try do
        unquote(declaration)
        unquote(__MODULE__).finish!(__ENV__)
      after
        unquote(__MODULE__).restore!(__ENV__, unquote(previous))
      end
    end
  end

  @doc false
  @spec enter!(Macro.Env.t(), atom(), String.t() | :otherwise) :: map() | nil
  def enter!(caller, kind, name) do
    previous = Module.get_attribute(caller.module, @scope)
    parent_path = if previous, do: previous.path, else: [host: Jido.Flow]

    Module.put_attribute(caller.module, @scope, %{
      path: parent_path ++ [{kind, name}],
      fields: %{},
      pending: [],
      nested?: not is_nil(previous),
      accepted?: false
    })

    previous
  end

  @doc false
  @spec restore!(Macro.Env.t(), map() | nil) :: :ok
  def restore!(caller, nil) do
    Module.delete_attribute(caller.module, @scope)
    :ok
  end

  def restore!(caller, previous) do
    current = Module.get_attribute(caller.module, @scope)

    previous =
      if current.accepted?,
        do: %{previous | pending: current.pending ++ previous.pending},
        else: previous

    Module.put_attribute(caller.module, @scope, previous)
  end

  @doc false
  @spec claim_inline!(Macro.Env.t(), atom(), atom()) :: Inline.path()
  def claim_inline!(caller, role, params) do
    scope = scope!(caller)
    for field <- [role, params], do: check_field!(scope, field, caller)
    fields = scope.fields |> Map.put(role, :inline) |> Map.put(params, :inline)
    Module.put_attribute(caller.module, @scope, %{scope | fields: fields})
    scope.path ++ [role: role]
  end

  @doc false
  @spec claim_field!(Macro.Env.t(), atom()) :: :ok
  def claim_field!(caller, field) do
    scope = scope!(caller)
    # Ordinary duplicate fields still reach Spark's field validation.
    if Map.get(scope.fields, field) == :inline, do: conflict!(caller, field)

    Module.put_attribute(caller.module, @scope, %{
      scope
      | fields: Map.put(scope.fields, field, :explicit)
    })
  end

  defp check_field!(scope, field, caller) do
    if Map.has_key?(scope.fields, field), do: conflict!(caller, field)
  end

  @spec conflict!(Macro.Env.t(), atom()) :: no_return()
  defp conflict!(caller, field),
    do:
      MacroSupport.compile_error!(
        caller,
        "inline Action conflicts with an existing #{field} field"
      )

  defp scope!(caller) do
    case Module.get_attribute(caller.module, @scope) do
      %{path: [{:host, Jido.Flow}, {kind, _}]} = scope
      when kind in [:step, :map, :reduce, :choice, :iterate] ->
        scope

      %{path: [host: Jido.Flow, choice: _, option: _]} = scope ->
        scope

      %{path: [host: Jido.Flow, choice: _, fallback: :otherwise]} = scope ->
        scope

      _ ->
        MacroSupport.compile_error!(
          caller,
          "inline Action field requires a supported Flow declaration scope"
        )
    end
  end

  @doc false
  @spec defer!([term()]) :: :ok
  def defer!(args) do
    caller = List.last(args)
    scope = scope!(caller)
    Module.put_attribute(caller.module, @scope, %{scope | pending: [args | scope.pending]})
  end

  @doc false
  @spec finish!(Macro.Env.t()) :: :ok
  def finish!(caller) do
    scope = scope!(caller)
    # Nested Choice targets wait until Spark also accepts their parent.
    unless scope.nested? do
      for args <- Enum.reverse(scope.pending), do: apply(Inline.Compiler, :create_action!, args)
    end

    Module.put_attribute(caller.module, @scope, %{scope | accepted?: true})
    :ok
  end

  @doc false
  @spec declaration_imports(Macro.Env.t()) :: [{module(), keyword()}]
  def declaration_imports(caller) do
    # Exact host-owned declaration modules; application helpers remain imported.
    modules =
      [
        Jido.Flow.DSL,
        Spark.Dsl,
        Jido.Flow.DSL.Extension,
        Jido.Flow.DSL.Macros,
        Jido.Flow.DSL.ChoiceMacros,
        Jido.Flow.DSL.IterateMacros,
        __MODULE__
      ] ++
        @field_adapters ++
        for segments <- [
              [],
              ["Step"],
              ["Map"],
              ["Reduce"],
              ["Choice"],
              ["Choice", "Option"],
              ["Choice", "Otherwise"],
              ["Iterate"],
              ["Iterate", "State"],
              ["Dispatch"],
              ["Output"]
            ],
            suffix <- [[], ["Options"]] do
          Module.concat([Jido.Flow.DSL.Extension, "Flow"] ++ segments ++ suffix)
        end

    for module <- modules,
        imports =
          Keyword.get(caller.functions, module, []) ++ Keyword.get(caller.macros, module, []),
        imports != [],
        do: {module, Enum.uniq(imports)}
  end
end

# These imports select a field setter without adding aliases or changing the
# owner's lexical environment. All parsing and compilation stays above.
for {segments, label, supported?} <- [
      {["Step"], "Step", true},
      {["Map"], "Map", true},
      {["Reduce"], "Reduce", true},
      {["Choice"], "Choice", false},
      {["Choice", "Option"], "Choice option", true},
      {["Choice", "Otherwise"], "Choice fallback", true},
      {["Iterate"], "Iterate", true},
      {["Iterate", "State"], "Iterate state", false}
    ] do
  defmodule Module.concat([Jido.Flow.DSL.InlineAction | segments]) do
    @moduledoc false
    @setter if(supported?,
              do: Module.concat([Jido.Flow.DSL.Extension.Flow | segments] ++ ["Options"])
            )
    @label label

    defmacro action(value),
      do: Jido.Flow.DSL.InlineAction.field(:action, value, __CALLER__, @setter, @label)

    defmacro params(value),
      do: Jido.Flow.DSL.InlineAction.field(:params, value, __CALLER__, @setter, @label)

    defmacro action(bindings, options),
      do: Jido.Flow.DSL.InlineAction.bound(bindings, options, __CALLER__, @setter, @label)

    defmacro action(bindings, options, body_options),
      do:
        Jido.Flow.DSL.InlineAction.bound_options(
          bindings,
          options,
          body_options,
          __CALLER__,
          @setter,
          @label
        )
  end
end
