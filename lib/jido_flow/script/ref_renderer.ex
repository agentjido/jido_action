defmodule Jido.Flow.Script.RefRenderer do
  @moduledoc false

  @spec ref(term()) :: String.t()
  def ref({:input, name}), do: "input(#{atom(name)})"
  def ref({:result, name}), do: "result(#{atom(name)})"
  def ref({:result, name, path}), do: "result(#{atom(name)}, #{value(path)})"
  def ref({:value, value}), do: "value(#{value(value)})"
  def ref(name) when is_atom(name), do: atom(name)

  @spec over(term()) :: String.t()
  def over({name, opts}) when is_atom(name) and is_list(opts) do
    opts =
      Enum.map_join(opts, ", ", fn {key, option_value} ->
        "#{keyword_key(key)}: #{value(option_value)}"
      end)

    "{#{atom(name)}, #{opts}}"
  end

  def over(value), do: value(value)

  defp atom(nil), do: "nil"
  defp atom(value) when is_atom(value), do: inspect(value)
  defp keyword_key(value) when is_atom(value), do: Atom.to_string(value)
  defp value(value), do: inspect(value, charlists: :as_lists)
end
