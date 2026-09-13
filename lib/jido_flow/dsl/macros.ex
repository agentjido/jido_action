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
  @spec entity(
          [Macro.t()],
          term(),
          module(),
          atom(),
          [atom()],
          Macro.Env.t(),
          {String.t(), String.t()}
        ) :: Macro.t()
  def entity(arguments, options, module, function, fields, caller, {label, mixed_label}) do
    validate_options!(
      options,
      caller,
      "#{label} options must be a keyword list",
      "#{label} field"
    )

    arguments = arguments ++ [source(caller)]

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = quote_fields(short_options, fields)

        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).unquote(function)(
            unquote_splicing(arguments),
            unquote(short_options)
          )
        end

      {block, []} ->
        quote generated: true, line: caller.line, file: caller.file do
          require unquote(module)

          unquote(module).unquote(function)(unquote_splicing(arguments)) do
            unquote(block)
          end
        end

      {_block, _mixed_options} ->
        compile_error!(caller, "do not mix keyword and block fields in #{mixed_label}")
    end
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
  alias Jido.Flow.DSL.{InlineStep, MacroSupport, ModuleCompiler}

  defmacro step(name, options) do
    caller = __CALLER__
    step_name = Macro.unique_var(:step_name, __MODULE__)

    declaration =
      entity(step_name, options, extension_module(["Flow", "Step"]), :__step__, [:params], caller)

    quote line: caller.line do
      unquote(step_name) = unquote(name)
      unquote(ModuleCompiler).register_step!(unquote(step_name), __ENV__)
      unquote(declaration)
    end
  end

  defmacro step(name, bindings, options) do
    inline_step(name, InlineStep.parse!(bindings, options, __CALLER__), __CALLER__)
  end

  defmacro step(name, bindings, options, body_options) do
    inline_step(
      name,
      InlineStep.parse!(bindings, options, body_options, __CALLER__),
      __CALLER__
    )
  end

  defp inline_step(name_ast, %{action: action, component_options: component_options}, caller) do
    name = Macro.unique_var(:step_name, __MODULE__)
    path = quote do: [host: Jido.Flow, step: unquote(name), role: :action]

    # Keep the loaded Action unchanged if Spark rejects this Step's fields.
    compiled =
      Inline.Compiler.compile!(path, action, caller,
        default_name: name,
        reserved_label: "Flow",
        module_label: "inline Step",
        emit: {InlineStep, :defer!},
        remove_imports: InlineStep.declaration_imports(caller)
      )

    options = [action: compiled.target_ast, params: action.params_ast] ++ component_options

    declaration =
      entity(name, options, extension_module(["Flow", "Step"]), :__step__, [:params], caller)

    quote line: caller.line do
      unquote(name) = unquote(ModuleCompiler).register_step!(unquote(name_ast), __ENV__)
      unquote(compiled.declaration_ast)
      unquote(declaration)
      unquote(InlineStep).emit!(__ENV__)
    end
  end

  defmacro map(name, options) do
    named_entity(name, options, "Map", :__map__, [:collection, :params], __CALLER__)
  end

  defmacro reduce(name, options) do
    named_entity(
      name,
      options,
      "Reduce",
      :__reduce__,
      [:collection, :initial, :params],
      __CALLER__
    )
  end

  defmacro choice(name, options) do
    named_block_entity(name, options, "Choice", :__choice__, __CALLER__)
  end

  defmacro iterate(name, options) do
    named_block_entity(name, options, "Iterate", :__iterate__, __CALLER__)
  end

  defp named_entity(name, options, segment, function, quoted_fields, caller) do
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

    named_declaration(name, evaluated_name, declaration, caller)
  end

  defp named_block_entity(name, options, segment, function, caller) do
    evaluated_name = Macro.unique_var(:declaration_name, __MODULE__)

    declaration =
      block_entity(evaluated_name, options, extension_module(["Flow", segment]), function, caller)

    named_declaration(name, evaluated_name, declaration, caller)
  end

  defp named_declaration(name, evaluated_name, declaration, caller) do
    quote line: caller.line do
      unquote(evaluated_name) = unquote(name)
      unquote(declaration)
    end
  end

  defmacro dispatch(name, options) do
    named_entity(name, options, "Dispatch", :__dispatch__, [:params], __CALLER__)
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
    MacroSupport.entity(
      [name],
      options,
      module,
      function,
      quoted_fields,
      caller,
      {"Flow declaration", "one declaration"}
    )
  end

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

  alias Jido.Flow.DSL.MacroSupport

  defmacro option(name, options) do
    evaluated_name = Macro.unique_var(:option_name, __MODULE__)

    declaration =
      nested_entity(
        [evaluated_name],
        options,
        extension_module(["Flow", "Choice", "Option"]),
        :__option__,
        [:condition, :params],
        __CALLER__
      )

    quote line: __CALLER__.line do
      unquote(evaluated_name) = unquote(name)
      unquote(declaration)
    end
  end

  defmacro otherwise(options) do
    nested_entity(
      [],
      options,
      extension_module(["Flow", "Choice", "Otherwise"]),
      :__otherwise__,
      [:params],
      __CALLER__
    )
  end

  defp nested_entity(arguments, options, module, function, quoted_fields, caller) do
    MacroSupport.entity(
      arguments,
      options,
      module,
      function,
      quoted_fields,
      caller,
      {"Choice declaration", "one Choice target"}
    )
  end

  defp extension_module(segments) do
    Module.concat(["Jido", "Flow", "DSL", "Extension" | segments])
  end
end

defmodule Jido.Flow.DSL.IterateMacros do
  @moduledoc false

  alias Jido.Flow.DSL.MacroSupport

  defmacro state(schema, options) do
    MacroSupport.entity(
      [schema],
      options,
      extension_module(["Flow", "Iterate", "State"]),
      :__state__,
      [:initial],
      __CALLER__,
      {"Iterate state", "Iterate state"}
    )
  end

  defp extension_module(segments) do
    Module.concat(["Jido", "Flow", "DSL", "Extension" | segments])
  end
end
