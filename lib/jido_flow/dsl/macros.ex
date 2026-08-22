defmodule Jido.Flow.DSL.Macros do
  @moduledoc false

  @step Jido.Flow.DSL.Extension.Flow.Step
  @choice Jido.Flow.DSL.Extension.Flow.Choice
  @map Jido.Flow.DSL.Extension.Flow.Map
  @reduce Jido.Flow.DSL.Extension.Flow.Reduce
  @iterate Jido.Flow.DSL.Extension.Flow.Iterate

  defmacro step(name, options) do
    entity(name, options, @step, :__step__, [:params], __CALLER__)
  end

  defmacro map(name, options) do
    entity(name, options, @map, :__map__, [:collection, :params], __CALLER__)
  end

  defmacro reduce(name, options) do
    entity(
      name,
      options,
      @reduce,
      :__reduce__,
      [:collection, :initial, :params],
      __CALLER__
    )
  end

  defmacro choice(name, options) do
    block_entity(name, options, @choice, :__choice__, __CALLER__)
  end

  defmacro iterate(name, options) do
    block_entity(name, options, @iterate, :__iterate__, __CALLER__)
  end

  defp entity(name, options, module, function, quoted_fields, caller) do
    validate_options!(options, caller)

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = quote_fields(short_options, quoted_fields)

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
        compile_error!(caller, "do not mix keyword and block fields in one declaration")
    end
  end

  defp block_entity(name, options, module, function, caller) do
    validate_options!(options, caller)

    case options do
      [do: block] ->
        quote generated: true do
          require unquote(module)

          unquote(module).unquote(function)(unquote(name)) do
            unquote(block)
          end
        end

      _options ->
        compile_error!(caller, "this Flow declaration requires a do block")
    end
  end

  defp quote_fields(options, fields) do
    Enum.map(options, fn {field, value} = option ->
      if field in fields, do: {field, Macro.escape(value)}, else: option
    end)
  end

  defp validate_options!(options, caller) do
    if Keyword.keyword?(options) do
      case first_duplicate(Keyword.keys(options)) do
        {:ok, field} ->
          compile_error!(caller, "duplicate Flow declaration field: #{inspect(field)}")

        :none ->
          :ok
      end
    else
      compile_error!(caller, "Flow declaration options must be a keyword list")
    end
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

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule Jido.Flow.DSL.ChoiceMacros do
  @moduledoc false

  @option Jido.Flow.DSL.Extension.Flow.Choice.Option
  @otherwise Jido.Flow.DSL.Extension.Flow.Choice.Otherwise

  defmacro option(name, options) do
    nested_entity(name, options, @option, :__option__, [:condition, :params], __CALLER__)
  end

  defmacro otherwise(options) do
    nested_entity(nil, options, @otherwise, :__otherwise__, [:params], __CALLER__)
  end

  defp nested_entity(name, options, module, function, quoted_fields, caller) do
    validate_options!(options, caller)

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options = quote_fields(short_options, quoted_fields)
        call_nested(module, function, name, short_options)

      {block, []} ->
        call_nested_block(module, function, name, block)

      {_block, _mixed_options} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "do not mix keyword and block fields in one Choice target"
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

  defp quote_fields(options, fields) do
    Enum.map(options, fn {field, value} = option ->
      if field in fields, do: {field, Macro.escape(value)}, else: option
    end)
  end

  defp validate_options!(options, caller) do
    if Keyword.keyword?(options) do
      case first_duplicate(Keyword.keys(options)) do
        {:ok, field} ->
          compile_error!(caller, "duplicate Choice declaration field: #{inspect(field)}")

        :none ->
          :ok
      end
    else
      compile_error!(caller, "Choice declaration options must be a keyword list")
    end
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

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule Jido.Flow.DSL.IterateMacros do
  @moduledoc false

  @state Jido.Flow.DSL.Extension.Flow.Iterate.State

  defmacro state(schema, options) do
    validate_options!(options, __CALLER__)

    case Keyword.pop(options, :do) do
      {nil, short_options} ->
        short_options =
          Enum.map(short_options, fn
            {:initial, value} -> {:initial, Macro.escape(value)}
            option -> option
          end)

        quote generated: true do
          require unquote(@state)
          unquote(@state).__state__(unquote(schema), unquote(short_options))
        end

      {block, []} ->
        quote generated: true do
          require unquote(@state)

          unquote(@state).__state__ unquote(schema) do
            unquote(block)
          end
        end

      {_block, _mixed_options} ->
        raise CompileError,
          file: __CALLER__.file,
          line: __CALLER__.line,
          description: "do not mix keyword and block fields in Iterate state"
    end
  end

  defp validate_options!(options, caller) do
    if Keyword.keyword?(options) do
      case first_duplicate(Keyword.keys(options)) do
        {:ok, field} ->
          compile_error!(caller, "duplicate Iterate state field: #{inspect(field)}")

        :none ->
          :ok
      end
    else
      compile_error!(caller, "Iterate state options must be a keyword list")
    end
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

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end
