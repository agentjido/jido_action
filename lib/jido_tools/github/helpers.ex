defmodule Jido.Tools.Github.Helpers do
  @moduledoc """
  Shared helper utilities for GitHub action modules.
  """

  @type response_payload :: %{status: String.t(), data: any(), raw: any()}

  @doc """
  Resolves a Tentacat client from params or context.
  """
  @spec client(map(), map()) :: any()
  def client(params, context) do
    params[:client] || context[:client] || get_in(context, [:tool_context, :client])
  end

  @doc """
  Normalizes successful API results into the standard tool payload shape.
  """
  @spec success(any()) :: {:ok, response_payload()}
  def success(result) do
    {:ok,
     %{
       status: "success",
       data: result,
       raw: result
     }}
  end

  @doc """
  Removes keys with `nil` values from a map.
  """
  @spec compact_nil(map()) :: map()
  def compact_nil(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Removes keys with `nil` or blank-string values from a map.
  """
  @spec compact_blank(map()) :: map()
  def compact_blank(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  @doc """
  Puts a key/value pair only when the value is not `nil`.
  """
  @spec maybe_put(map(), any(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
