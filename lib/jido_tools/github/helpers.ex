defmodule Jido.Tools.Github.Helpers do
  @moduledoc false

  @type response_payload :: %{status: String.t(), data: any(), raw: any()}

  @spec client(map(), map()) :: any()
  def client(params, context) do
    params[:client] || context[:client] || get_in(context, [:tool_context, :client])
  end

  @spec success(any()) :: {:ok, response_payload()}
  def success(result) do
    {:ok,
     %{
       status: "success",
       data: result,
       raw: result
     }}
  end

  @spec compact_nil(map()) :: map()
  def compact_nil(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec compact_blank(map()) :: map()
  def compact_blank(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  @spec maybe_put(map(), any(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
