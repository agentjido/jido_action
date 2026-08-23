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

  defp entity(name, options, module, function, quoted_fields, caller) do
    MacroSupport.validate_options!(
      options,
      caller,
      "Flow declaration options must be a keyword list",
      "Flow declaration field"
    )

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = MacroSupport.quote_fields(short_options, quoted_fields)

        quote generated: true do
          require unquote(module)
          unquote(module).unquote(function)(unquote(name), unquote(short_options))
        end

      {block, []} ->
        quote generated: true do
          require unquote(module)

          unquote(module).unquote(function)(unquote(name)) do
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

    case options do
      [do: block] ->
        quote generated: true do
          require unquote(module)

          unquote(module).unquote(function)(unquote(name)) do
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

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = MacroSupport.quote_fields(short_options, quoted_fields)
        call_nested(module, function, name, short_options)

      {block, []} ->
        call_nested_block(module, function, name, block)

      {_block, _mixed_options} ->
        MacroSupport.compile_error!(
          caller,
          "do not mix keyword and block fields in one Choice target"
        )
    end
  end

  defp call_nested(module, function, nil, options) do
    quote generated: true do
      require unquote(module)
      unquote(module).unquote(function)(unquote(options))
    end
  end

  defp call_nested(module, function, name, options) do
    quote generated: true do
      require unquote(module)
      unquote(module).unquote(function)(unquote(name), unquote(options))
    end
  end

  defp call_nested_block(module, _function, nil, block) do
    quote generated: true do
      require unquote(module)

      unquote(module).__otherwise__ do
        unquote(block)
      end
    end
  end

  defp call_nested_block(module, function, name, block) do
    quote generated: true do
      require unquote(module)

      unquote(module).unquote(function)(unquote(name)) do
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
    MacroSupport.validate_options!(
      options,
      __CALLER__,
      "Iterate state options must be a keyword list",
      "Iterate state field"
    )

    module = extension_module(["Flow", "Iterate", "State"])

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = MacroSupport.quote_fields(short_options, [:initial])

        quote generated: true do
          require unquote(module)
          unquote(module).__state__(unquote(schema), unquote(short_options))
        end

      {block, []} ->
        quote generated: true do
          require unquote(module)

          unquote(module).__state__ unquote(schema) do
            unquote(block)
          end
        end

      {_block, _mixed_options} ->
        MacroSupport.compile_error!(
          __CALLER__,
          "do not mix keyword and block fields in Iterate state"
        )
    end
  end

  defp extension_module(segments) do
    Module.concat(["Jido", "Flow", "DSL", "Extension" | segments])
  end
end
