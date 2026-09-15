defmodule Jido.Flow.Component.Fields do
  @moduledoc false

  alias Jido.Action
  alias Jido.Flow.Data
  alias Jido.Flow.Error

  @doc false
  @spec name(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def name(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> name()

  def name(value) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  def name(_value),
    do: {:error, Error.validation_error("component name must be a non-empty string")}

  @doc false
  @spec module(term(), String.t()) :: {:ok, module()} | {:error, Exception.t()}
  def module(value, _label) when is_atom(value) and not is_nil(value), do: {:ok, value}

  def module(_value, label) do
    {:error, Error.validation_error("#{label} must be a module atom")}
  end

  @doc false
  @spec needs_names(term()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def needs_names(nil), do: {:ok, []}

  def needs_names(values) when is_list(values) do
    if List.improper?(values) do
      {:error, Error.validation_error("component needs must be a proper list")}
    else
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, names} ->
        case name(value) do
          {:ok, name} ->
            {:cont, {:ok, [name | names]}}

          {:error, _error} ->
            {:halt,
             {:error, Error.validation_error("component needs must contain component names")}}
        end
      end)
      |> reject_duplicate_needs()
    end
  end

  def needs_names(_values), do: {:error, Error.validation_error("component needs must be a list")}

  @doc false
  @spec meta(term()) :: {:ok, Data.object()} | {:error, Exception.t()}
  def meta(nil), do: {:ok, %{}}

  def meta(value) do
    case Data.validate_object(value) do
      :ok -> {:ok, value}
      {:error, error} -> {:error, error}
    end
  end

  defp reject_duplicate_needs({:ok, reversed_names}) do
    names = Enum.reverse(reversed_names)

    case names -- Enum.uniq(names) do
      [] ->
        {:ok, names}

      [name | _] ->
        {:error, Error.validation_error("component needs contains a duplicate", %{name: name})}
    end
  end

  defp reject_duplicate_needs(error), do: error
end
