defmodule Jido.Flow.DSL.MacroSupport do
  @moduledoc false

  @doc false
  @spec validate_options!(term(), Macro.Env.t(), String.t(), String.t()) :: :ok | no_return()
  def validate_options!(options, caller, options_message, duplicate_label) do
    if Keyword.keyword?(options) do
      case first_duplicate(Keyword.keys(options)) do
        {:ok, field} ->
          compile_error!(caller, "duplicate #{duplicate_label}: #{inspect(field)}")

        :none ->
          :ok
      end
    else
      compile_error!(caller, options_message)
    end
  end

  @doc false
  @spec quote_fields(keyword(), [atom()]) :: keyword()
  def quote_fields(options, fields) do
    Enum.map(options, fn {field, value} = option ->
      if field in fields, do: {field, Macro.escape(value)}, else: option
    end)
  end

  @doc false
  @spec source(Macro.Env.t()) :: Macro.t()
  def source(caller), do: Macro.escape(%{line: caller.line})

  @doc false
  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  def compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp first_duplicate(values) do
    values
    |> Enum.reduce_while(MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value),
        do: {:halt, {:ok, value}},
        else: {:cont, MapSet.put(seen, value)}
    end)
    |> then(fn
      %MapSet{} -> :none
      duplicate -> duplicate
    end)
  end
end

defmodule Jido.Flow.DSL.Macros do
  @moduledoc false

  alias Jido.Action.Inline
  alias Jido.Flow.DSL.{InlineAction, InlineStep, MacroSupport, ModuleCompiler}

  defmacro step(name, options) do
    caller = __CALLER__
    step_name = Macro.unique_var(:step_name, __MODULE__)

    declaration =
      entity(step_name, options, extension_module(["Flow", "Step"]), :__step__, [:params], caller)

    declaration = InlineAction.scoped(step_name, :step, declaration, caller)

    quote line: caller.line do
      unquote(step_name) = unquote(name)
      unquote(ModuleCompiler).register_step!(unquote(step_name), __ENV__)
      unquote(declaration)
    end
  end

  defmacro step(name, bindings, options) do
    inline_step(name, InlineStep.parse!(bindings, options, __CALLER__), __CALLER__)
  end

  defmacro step(name, left, right, options) do
    inline_step(name, InlineStep.parse!(left, right, options, __CALLER__), __CALLER__)
  end

  defmacro step(name, left, right, options, body_options) do
    inline_step(
      name,
      InlineStep.parse!(left, right, options, body_options, __CALLER__),
      __CALLER__
    )
  end

  defp inline_step(name_ast, parsed, caller) do
    name = Macro.unique_var(:step_name, __MODULE__)
    path = quote do: [host: Jido.Flow, step: unquote(name), role: :action]

    compiled =
      Inline.Compiler.compile!(path, %{parsed | options: []}, caller,
        default_name: name,
        reserved_label: "Flow",
        module_label: "inline Step",
        remove_imports: InlineAction.declaration_imports(caller)
      )

    options = [action: compiled.target_ast, params: parsed.params_ast] ++ parsed.options

    declaration =
      entity(name, options, extension_module(["Flow", "Step"]), :__step__, [:params], caller)

    quote line: caller.line do
      unquote(name) = unquote(ModuleCompiler).register_step!(unquote(name_ast), __ENV__)
      unquote(compiled.declaration_ast)
      unquote(declaration)
    end
  end

  defmacro map(name, options) do
    scoped_entity(name, :map, options, "Map", :__map__, [:collection, :params], __CALLER__)
  end

  defmacro reduce(name, options) do
    scoped_entity(
      name,
      :reduce,
      options,
      "Reduce",
      :__reduce__,
      [:collection, :initial, :params],
      __CALLER__
    )
  end

  defmacro choice(name, options) do
    scoped_block_entity(name, :choice, options, "Choice", :__choice__, __CALLER__)
  end

  defmacro iterate(name, options) do
    scoped_block_entity(name, :iterate, options, "Iterate", :__iterate__, __CALLER__)
  end

  defp scoped_entity(name, kind, options, segment, function, quoted_fields, caller) do
    evaluated_name = Macro.unique_var(:declaration_name, __MODULE__)

    declaration =
      entity(
        evaluated_name,
        options,
        extension_module(["Flow", segment]),
        function,
        quoted_fields,
        caller
      )

    scoped_declaration(name, evaluated_name, kind, declaration, caller)
  end

  defp scoped_block_entity(name, kind, options, segment, function, caller) do
    evaluated_name = Macro.unique_var(:declaration_name, __MODULE__)

    declaration =
      block_entity(evaluated_name, options, extension_module(["Flow", segment]), function, caller)

    scoped_declaration(name, evaluated_name, kind, declaration, caller)
  end

  defp scoped_declaration(name, evaluated_name, kind, declaration, caller) do
    scoped = InlineAction.scoped(evaluated_name, kind, declaration, caller)

    quote line: caller.line do
      unquote(evaluated_name) = unquote(name)
      unquote(scoped)
    end
  end

  defmacro dispatch(name, options) do
    scoped_entity(name, :dispatch, options, "Dispatch", :__dispatch__, [:params], __CALLER__)
  end

  defmacro output(value) do
    caller = __CALLER__
    module = extension_module(["Flow", "Output"])
    source = MacroSupport.source(caller)

    quote generated: true, line: caller.line, file: caller.file do
      require unquote(module)
      unquote(module).__output__(unquote(value), unquote(source))
    end
  end

  defp entity(name, options, module, function, quoted_fields, caller) do
    MacroSupport.validate_options!(
      options,
      caller,
      "Flow declaration options must be a keyword list",
      "Flow declaration field"
    )

    source = MacroSupport.source(caller)

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = MacroSupport.quote_fields(short_options, quoted_fields)

        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).unquote(function)(
            unquote(name),
            unquote(source),
            unquote(short_options)
          )
        end

      {block, []} ->
        block = action_fields(block, module)

        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).unquote(function)(unquote(name), unquote(source)) do
            unquote(block)
          end
        end

      {_block, _mixed_options} ->
        MacroSupport.compile_error!(
          caller,
          "do not mix keyword and block fields in one declaration"
        )
    end
  end

  defp action_fields(block, module)
       when module in [
              Jido.Flow.DSL.Extension.Flow.Step,
              Jido.Flow.DSL.Extension.Flow.Map,
              Jido.Flow.DSL.Extension.Flow.Reduce,
              Jido.Flow.DSL.Extension.Flow.Iterate,
              Jido.Flow.DSL.Extension.Flow.Choice,
              Jido.Flow.DSL.Extension.Flow.Dispatch
            ],
       do: InlineAction.fields(block, module)

  defp action_fields(block, _module), do: block

  defp block_entity(name, options, module, function, caller) do
    MacroSupport.validate_options!(
      options,
      caller,
      "Flow declaration options must be a keyword list",
      "Flow declaration field"
    )

    source = MacroSupport.source(caller)

    case options do
      [do: block] ->
        block = action_fields(block, module)

        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).unquote(function)(unquote(name), unquote(source)) do
            unquote(block)
          end
        end

      _options ->
        MacroSupport.compile_error!(caller, "this Flow declaration requires a do block")
    end
  end

  defp extension_module(segments) do
    Module.concat(["Jido", "Flow", "DSL", "Extension" | segments])
  end
end

defmodule Jido.Flow.DSL.ChoiceMacros do
  @moduledoc false

  alias Jido.Flow.DSL.{InlineAction, MacroSupport}

  defmacro option(name, options) do
    evaluated_name = Macro.unique_var(:option_name, __MODULE__)

    declaration =
      nested_entity(
        evaluated_name,
        options,
        extension_module(["Flow", "Choice", "Option"]),
        :__option__,
        [:condition, :params],
        __CALLER__
      )

    scoped = InlineAction.scoped(evaluated_name, :option, declaration, __CALLER__)

    quote line: __CALLER__.line do
      unquote(evaluated_name) = unquote(name)
      unquote(scoped)
    end
  end

  defmacro otherwise(options) do
    declaration =
      nested_entity(
        nil,
        options,
        extension_module(["Flow", "Choice", "Otherwise"]),
        :__otherwise__,
        [:params],
        __CALLER__
      )

    InlineAction.scoped(:otherwise, :fallback, declaration, __CALLER__)
  end

  defp nested_entity(name, options, module, function, quoted_fields, caller) do
    MacroSupport.validate_options!(
      options,
      caller,
      "Choice declaration options must be a keyword list",
      "Choice declaration field"
    )

    source = MacroSupport.source(caller)

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = MacroSupport.quote_fields(short_options, quoted_fields)

        call_nested(module, function, name, source, short_options, caller)

      {block, []} ->
        block = InlineAction.fields(block, module)
        call_nested_block(module, function, name, block, source, caller)

      {_block, _mixed_options} ->
        MacroSupport.compile_error!(
          caller,
          "do not mix keyword and block fields in one Choice target"
        )
    end
  end

  defp call_nested(module, function, nil, source, options, caller) do
    quote generated: true, line: caller.line, file: caller.file do
      require unquote(module)
      unquote(module).unquote(function)(unquote(source), unquote(options))
    end
  end

  defp call_nested(module, function, name, source, options, caller) do
    quote generated: true, line: caller.line, file: caller.file do
      require unquote(module)

      unquote(module).unquote(function)(
        unquote(name),
        unquote(source),
        unquote(options)
      )
    end
  end

  defp call_nested_block(module, _function, nil, block, source, caller) do
    quote generated: true, line: caller.line, file: caller.file do
      require unquote(module)

      unquote(module).__otherwise__ unquote(source) do
        unquote(block)
      end
    end
  end

  defp call_nested_block(module, function, name, block, source, caller) do
    quote generated: true, line: caller.line, file: caller.file do
      require unquote(module)

      unquote(module).unquote(function)(unquote(name), unquote(source)) do
        unquote(block)
      end
    end
  end

  defp extension_module(segments) do
    Module.concat(["Jido", "Flow", "DSL", "Extension" | segments])
  end
end

defmodule Jido.Flow.DSL.IterateMacros do
  @moduledoc false

  alias Jido.Flow.DSL.{InlineAction, MacroSupport}

  defmacro state(schema, options) do
    caller = __CALLER__

    MacroSupport.validate_options!(
      options,
      caller,
      "Iterate state options must be a keyword list",
      "Iterate state field"
    )

    module = extension_module(["Flow", "Iterate", "State"])
    source = MacroSupport.source(caller)

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = MacroSupport.quote_fields(short_options, [:initial])

        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).__state__(
            unquote(schema),
            unquote(source),
            unquote(short_options)
          )
        end

      {block, []} ->
        block = InlineAction.fields(block, module)

        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).__state__ unquote(schema), unquote(source) do
            unquote(block)
          end
        end

      {_block, _mixed_options} ->
        MacroSupport.compile_error!(
          caller,
          "do not mix keyword and block fields in Iterate state"
        )
    end
  end

  defp extension_module(segments) do
    Module.concat(["Jido", "Flow", "DSL", "Extension" | segments])
  end
end
