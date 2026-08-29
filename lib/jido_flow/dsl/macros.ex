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

  alias Jido.Flow.DSL.MacroSupport

  defmacro step(name, options) do
    entity(name, options, extension_module(["Flow", "Step"]), :__step__, [:params], __CALLER__)
  end

  defmacro map(name, options) do
    entity(
      name,
      options,
      extension_module(["Flow", "Map"]),
      :__map__,
      [:collection, :params],
      __CALLER__
    )
  end

  defmacro reduce(name, options) do
    entity(
      name,
      options,
      extension_module(["Flow", "Reduce"]),
      :__reduce__,
      [:collection, :initial, :params],
      __CALLER__
    )
  end

  defmacro choice(name, options) do
    block_entity(
      name,
      options,
      extension_module(["Flow", "Choice"]),
      :__choice__,
      __CALLER__
    )
  end

  defmacro iterate(name, options) do
    block_entity(
      name,
      options,
      extension_module(["Flow", "Iterate"]),
      :__iterate__,
      __CALLER__
    )
  end

  defmacro dispatch(name, options) do
    entity(
      name,
      options,
      extension_module(["Flow", "Dispatch"]),
      :__dispatch__,
      [:params],
      __CALLER__
    )
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
    nested_entity(
      name,
      options,
      extension_module(["Flow", "Choice", "Option"]),
      :__option__,
      [:condition, :params],
      __CALLER__
    )
  end

  defmacro otherwise(options) do
    nested_entity(
      nil,
      options,
      extension_module(["Flow", "Choice", "Otherwise"]),
      :__otherwise__,
      [:params],
      __CALLER__
    )
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

  alias Jido.Flow.DSL.MacroSupport

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
