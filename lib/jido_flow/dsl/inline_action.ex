defmodule Jido.Flow.DSL.InlineAction do
  @moduledoc false

  alias Jido.Action.Inline
  alias Jido.Flow.DSL.{Expression, MacroSupport}

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
    Jido.Flow.DSL.InlineAction.Iterate.State,
    Jido.Flow.DSL.InlineAction.Dispatch
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
  @spec bound_options(
          Macro.t(),
          keyword(),
          keyword(),
          Macro.Env.t(),
          module() | nil,
          String.t(),
          atom()
        ) ::
          Macro.t()
  def bound_options(bindings, options, body_options, caller, setter, label, role \\ :action) do
    options = body_options!(options, body_options, caller)
    bound(bindings, options, caller, setter, label, role)
  end

  defp body_options!(options, body_options, caller) do
    Inline.Parser.options!(
      options,
      [:name, :description, :schema, :output_schema, :context],
      caller
    )

    Inline.Parser.options!(body_options, [:do], caller)
    options ++ body_options
  end

  @doc false
  @spec bound(Macro.t(), keyword(), Macro.Env.t(), module() | nil, String.t()) :: Macro.t()
  @spec bound(Macro.t(), keyword(), Macro.Env.t(), module() | nil, String.t(), atom()) ::
          Macro.t()
  def bound(bindings, options, caller, setter, label, role \\ :action)

  def bound(_bindings, _options, caller, nil, label, _role),
    do: MacroSupport.compile_error!(caller, "#{label} does not accept an inline Action field")

  def bound(bindings, options, caller, setter, label, role) do
    parsed = parse_bound!(bindings, options, caller, label, role)
    validate_sources!(bindings, caller, "inline Action", params_scope(setter))
    path = Macro.unique_var(:inline_action_path, __MODULE__)
    compiled = compile_target(setter, path, parsed, caller)

    quote line: caller.line do
      unquote(path) = unquote(__MODULE__).claim_inline!(__ENV__, unquote(role), :params)
      unquote(compiled.declaration_ast)
      require unquote(setter)
      unquote(setter).unquote(role)(unquote(compiled.target_ast))
      unquote(setter).params(unquote(parsed.params_ast))
    end
  end

  defp params_scope(Jido.Flow.DSL.Extension.Flow.Map.Options), do: :map_params
  defp params_scope(Jido.Flow.DSL.Extension.Flow.Reduce.Options), do: :reduce_params
  defp params_scope(Jido.Flow.DSL.Extension.Flow.Iterate.Options), do: :iterate_params
  defp params_scope(_setter), do: :flow

  defp parse_bound!(bindings, options, caller, "Step", :action),
    do: Inline.parse_bound!(bindings, options, caller)

  defp parse_bound!(bindings, options, caller, label, role) do
    Inline.parse_bound!(bindings, options, caller)
  rescue
    error in CompileError ->
      reraise %{error | description: "#{label} #{role}: #{error.description}"}, __STACKTRACE__
  end

  @doc false
  @spec callback_options(Macro.t(), keyword(), keyword(), Macro.Env.t(), module(), String.t()) ::
          Macro.t()
  def callback_options(pattern, options, body_options, caller, setter, label) do
    callback(pattern, body_options!(options, body_options, caller), caller, setter, label)
  end

  @doc false
  @spec callback(Macro.t(), keyword(), Macro.Env.t(), module(), String.t()) :: Macro.t()
  def callback(pattern, options, caller, setter, label) do
    parsed = parse_callback!(pattern, options, caller, label)
    path = Macro.unique_var(:inline_action_path, __MODULE__)
    compiled = compile_target(setter, path, parsed, caller)

    quote line: caller.line do
      unquote(path) = unquote(__MODULE__).claim_inline!(__ENV__, :expander, nil)
      unquote(compiled.declaration_ast)
      require unquote(setter)
      unquote(setter).expander(unquote(compiled.target_ast))
    end
  end

  defp parse_callback!(pattern, options, caller, label) do
    Inline.parse_callback!(pattern, options, caller)
  rescue
    error in CompileError ->
      reraise %{error | description: "#{label} expander: #{error.description}"}, __STACKTRACE__
  end

  defp compile_target(setter, path, parsed, caller) do
    labels =
      if setter == @step_options,
        do: [reserved_label: "Flow", module_label: "inline Step"],
        else: []

    Inline.Compiler.compile!(
      path,
      parsed,
      caller,
      [
        default_name: quote(do: unquote(__MODULE__).default_name(unquote(path))),
        remove_imports: declaration_imports(caller),
        emit: {__MODULE__, :defer!}
      ] ++ labels
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
        fields =
          if module == Jido.Flow.DSL.Extension.Flow.Dispatch,
            do: [decision: 1, expander: 1, params: 1],
            else: [action: 1, params: 1]

        quote do
          import unquote(setter), except: unquote(fields)
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
  @spec validate_sources!(Macro.t(), Macro.Env.t(), String.t(), Jido.Flow.Ref.scope() | nil) ::
          :ok
  def validate_sources!(bindings, caller, label, scope \\ nil) do
    for {:<-, _, [_pattern, source]} <- List.wrap(bindings) do
      validate_source!(source, caller, label, scope)
    end

    :ok
  end

  defp validate_source!(source, caller, label, scope) do
    # Legacy Step shorthand keeps its parse-time diagnostics. Bound fields also
    # check their slot scope before compiling a replacement wrapper.
    with {:ok, expression} <- Expression.parse(source),
         :ok <- if(scope, do: Jido.Flow.Expression.validate(expression, scope), else: :ok) do
      :ok
    else
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
  @spec claim_inline!(Macro.Env.t(), atom(), atom() | nil) :: Inline.path()
  def claim_inline!(caller, role, params) do
    scope = scope!(caller)
    claimed = if params, do: [role, params], else: [role]
    for field <- claimed, do: check_field!(scope, field, caller)
    fields = Enum.reduce(claimed, scope.fields, &Map.put(&2, &1, :inline))
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
      when kind in [:step, :map, :reduce, :choice, :iterate, :dispatch] ->
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

defmodule Jido.Flow.DSL.InlineAction.Dispatch do
  @moduledoc false

  alias Jido.Flow.DSL.InlineAction
  @setter Jido.Flow.DSL.Extension.Flow.Dispatch.Options

  for field <- [:decision, :expander, :params] do
    defmacro unquote(field)(value),
      do: InlineAction.field(unquote(field), value, __CALLER__, @setter, "Dispatch")
  end

  defmacro decision(bindings, options),
    do: InlineAction.bound(bindings, options, __CALLER__, @setter, "Dispatch", :decision)

  defmacro decision(bindings, options, body_options),
    do:
      InlineAction.bound_options(
        bindings,
        options,
        body_options,
        __CALLER__,
        @setter,
        "Dispatch",
        :decision
      )

  defmacro expander(pattern, options),
    do: InlineAction.callback(pattern, options, __CALLER__, @setter, "Dispatch")

  defmacro expander(pattern, options, body_options),
    do:
      InlineAction.callback_options(
        pattern,
        options,
        body_options,
        __CALLER__,
        @setter,
        "Dispatch"
      )
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
