defmodule Jido.Flow.DSL.MacroSupport do
  @moduledoc false

  @doc false
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
  def quote_fields(options, fields) do
    Enum.map(options, fn {field, value} = option ->
      if field in fields, do: {field, Macro.escape(value)}, else: option
    end)
  end

  @doc false
  def source(caller), do: Macro.escape(%{line: caller.line})

  @doc false
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
