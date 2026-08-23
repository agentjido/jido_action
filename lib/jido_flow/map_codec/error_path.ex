defmodule Jido.Flow.MapCodec.ErrorPath do
  @moduledoc false

  alias Jido.Action.Error

  @doc false
  @spec error(String.t(), map()) :: {:error, Error.InvalidInputError.t()}
  def error(message, details \\ %{}), do: {:error, Error.validation_error(message, details)}

  @doc false
  @spec prepend({:ok, term()} | {:error, term()}, list()) :: {:ok, term()} | {:error, term()}
  def prepend({:ok, value}, _prefix), do: {:ok, value}

  def prepend({:error, %{details: details} = error}, prefix) when is_map(details) do
    case Map.fetch(details, :path) do
      {:ok, path} when is_list(path) ->
        {:error, %{error | details: Map.put(details, :path, prefix ++ path)}}

      {:ok, _path_value} ->
        {:error, error}

      :error ->
        suffix = if Map.has_key?(details, :field), do: [details.field], else: []
        {:error, %{error | details: Map.put(details, :path, prefix ++ suffix)}}
    end
  end

  def prepend(result, _prefix), do: result

  @doc false
  @spec raise_validation(String.t(), map()) :: no_return()
  def raise_validation(message, details), do: raise(Error.validation_error(message, details))
end
