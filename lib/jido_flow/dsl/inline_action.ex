defmodule Jido.Flow.DSL.InlineAction do
  @moduledoc false

  alias Jido.Action.Inline
  alias Jido.Flow.DSL.{Expression, InlineStepCompiler, MacroSupport}

  @scope :__jido_flow_inline_scope__
  @step_options Jido.Flow.DSL.Extension.Flow.Step.Options

  defmacro action(value), do: field(:action, value, __CALLER__)
  defmacro params(value), do: field(:params, value, __CALLER__)

  defmacro action(bindings, options), do: bound(bindings, options, __CALLER__)

  defmacro action(bindings, options, body_options) do
    Inline.Parser.options!(
      options,
      [:name, :description, :schema, :output_schema, :context],
      __CALLER__
    )

    Inline.Parser.options!(body_options, [:do], __CALLER__)
    bound(bindings, options ++ body_options, __CALLER__)
  end

  defp bound(bindings, options, caller) do
    parsed = Inline.parse_bound!(bindings, options, caller)
    validate_sources!(bindings, caller, "inline Action")
    name = Macro.unique_var(:inline_step_name, __MODULE__)

    compiled =
      InlineStepCompiler.compile_action!(name, parsed, caller, emit: {__MODULE__, :defer!})

    quote line: caller.line do
      unquote(name) = unquote(__MODULE__).claim_inline!(__ENV__, :action, :params)
      unquote(compiled.declaration_ast)
      require unquote(@step_options)
      unquote(@step_options).action(unquote(compiled.target_ast))
      unquote(@step_options).params(unquote(parsed.params_ast))
    end
  end

  defp field(field, value, caller) do
    quote line: caller.line do
      unquote(__MODULE__).claim_field!(__ENV__, unquote(field))
      require unquote(@step_options)
      unquote(@step_options).unquote(field)(unquote(value))
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
  @spec enter!(Macro.Env.t(), atom(), String.t()) :: map() | nil
  def enter!(caller, kind, name) do
    previous = Module.get_attribute(caller.module, @scope)
    parent_path = if previous, do: previous.path, else: [host: Jido.Flow]

    Module.put_attribute(caller.module, @scope, %{
      path: parent_path ++ [{kind, name}],
      fields: %{},
      pending: []
    })

    previous
  end

  @doc false
  @spec restore!(Macro.Env.t(), map() | nil) :: :ok
  def restore!(caller, nil) do
    Module.delete_attribute(caller.module, @scope)
    :ok
  end

  def restore!(caller, previous), do: Module.put_attribute(caller.module, @scope, previous)

  @doc false
  @spec claim_inline!(Macro.Env.t(), atom(), atom()) :: String.t()
  def claim_inline!(caller, role, params) do
    scope = scope!(caller)
    for field <- [role, params], do: check_field!(scope, field, caller)
    fields = scope.fields |> Map.put(role, :inline) |> Map.put(params, :inline)
    Module.put_attribute(caller.module, @scope, %{scope | fields: fields})
    Keyword.fetch!(scope.path, :step)
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
      %{path: [host: Jido.Flow, step: _]} = scope ->
        scope

      _ ->
        MacroSupport.compile_error!(
          caller,
          "inline Action field requires a supported Flow declaration scope (Step)"
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
    # Flush only this declaration's queue, after Spark accepts its fields.
    for args <- Enum.reverse(scope.pending), do: apply(Inline.Compiler, :create_action!, args)
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
