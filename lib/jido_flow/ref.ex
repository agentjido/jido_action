defmodule Jido.Flow.Ref do
  @moduledoc false

  @type path :: [atom() | non_neg_integer()]
  @type value_ref ::
          {:input, atom()}
          | {:result, atom()}
          | {:result, atom(), path()}
          | {:value, term()}
  @type over_ref :: atom() | {atom(), keyword()}

  @doc false
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate({:input, name}), do: validate_name(name)
  def validate({:result, name}), do: validate_name(name)

  def validate({:result, name, path}) do
    with :ok <- validate_name(name), do: validate_path(path)
  end

  def validate({:value, _value}), do: :ok
  def validate(_value), do: {:error, "must be a value reference"}

  @doc false
  @spec validate_path(term()) :: :ok | {:error, String.t()}
  def validate_path(path) when is_list(path) do
    cond do
      path == [] ->
        {:error, "path must be a non-empty list"}

      Enum.all?(path, &path_part?/1) ->
        :ok

      true ->
        {:error, "path must contain only atoms or non-negative integers"}
    end
  end

  def validate_path(_path), do: {:error, "path must be a non-empty list"}

  @doc false
  @spec normalize_source(term()) :: {:ok, value_ref() | nil} | {:error, String.t()}
  def normalize_source(nil), do: {:ok, nil}
  def normalize_source(name) when is_atom(name) and not is_nil(name), do: {:ok, {:result, name}}

  def normalize_source(source) do
    case validate(source) do
      :ok -> {:ok, source}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec normalize_over(term()) :: {:ok, over_ref() | nil} | {:error, String.t()}
  def normalize_over(nil), do: {:ok, nil}
  def normalize_over(name) when is_atom(name) and not is_nil(name), do: {:ok, name}

  def normalize_over({name, opts}) when is_atom(name) and not is_nil(name) and is_list(opts) do
    duplicate = if Keyword.keyword?(opts), do: duplicate_option(opts)

    cond do
      not Keyword.keyword?(opts) ->
        {:error, "over expects an atom or {:name, from: :source, path: [...]}"}

      duplicate in [:from, :path] ->
        {:error, "over option #{inspect(duplicate)} can only be declared once"}

      Keyword.keys(opts) -- [:from, :path] != [] ->
        {:error, "over supports only :from and :path"}

      true ->
        with :ok <- validate_name(Keyword.get(opts, :from)),
             :ok <- validate_path(Keyword.get(opts, :path)) do
          {:ok, {name, [from: Keyword.fetch!(opts, :from), path: Keyword.fetch!(opts, :path)]}}
        else
          {:error, "must be an atom"} -> {:error, "from must be an atom"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def normalize_over(_over),
    do: {:error, "over expects an atom or {:name, from: :source, path: [...]}"}

  @doc false
  @spec dependency(term()) :: atom() | nil
  def dependency({:result, name}) when is_atom(name), do: name
  def dependency({:result, name, _path}) when is_atom(name), do: name
  def dependency(_source), do: nil

  @doc false
  @spec over_dependency(term()) :: atom() | nil
  def over_dependency(name) when is_atom(name) and not is_nil(name), do: name
  def over_dependency({name, _opts}) when is_atom(name) and not is_nil(name), do: name
  def over_dependency(_other), do: nil

  @doc false
  @spec dependencies(map()) :: [atom()]
  def dependencies(arguments) when is_map(arguments) do
    arguments
    |> Map.values()
    |> Enum.flat_map(fn value ->
      case dependency(value) do
        nil -> []
        name -> [name]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec dependency_list(map()) :: atom() | [atom()] | nil
  def dependency_list(arguments) do
    case dependencies(arguments) do
      [] -> nil
      [name] -> name
      names -> names
    end
  end

  @doc false
  @spec map_from_source(term()) :: atom() | nil
  def map_from_source({:result, name}) when is_atom(name), do: name
  def map_from_source(_source), do: nil

  defp validate_name(value) when is_atom(value) and not is_nil(value), do: :ok
  defp validate_name(_value), do: {:error, "must be an atom"}

  defp path_part?(value) when is_atom(value) and not is_nil(value), do: true
  defp path_part?(value) when is_integer(value) and value >= 0, do: true
  defp path_part?(_value), do: false

  defp duplicate_option(opts) do
    opts
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.find_value(fn
      {key, count} when count > 1 -> key
      _option -> nil
    end)
  end
end
