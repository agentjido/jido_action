defmodule Jido.Flow.Compiler.SourceMap do
  @moduledoc false

  alias Jido.Flow.Compiled
  alias Jido.Flow.Error

  @doc false
  @spec prepare(keyword() | Compiled.source_map(), [module()]) ::
          {:ok, Compiled.source_map()} | {:error, Exception.t()}
  def prepare(opts, module_stack) do
    case source_map(opts) do
      {:ok, source_map} ->
        {:ok, source_map}

      {:error, error} ->
        {:error, add_source_map_flow(error, module_stack)}
    end
  end

  defp add_source_map_flow(error, [module | _rest]),
    do: %{error | details: Map.put(error.details, :flow, module)}

  defp add_source_map_flow(error, []), do: error

  defp source_map(opts) when is_map(opts) and not is_struct(opts),
    do: validate_source_map(opts)

  defp source_map(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        source_map_error("Flow compile options must be a keyword list or source map")

      Keyword.keys(opts) -- [:source_map] != [] ->
        [option | _rest] = Keyword.keys(opts) -- [:source_map]
        source_map_error("unknown Flow compile option: #{inspect(option)}", %{option: option})

      Keyword.get_values(opts, :source_map) |> length() > 1 ->
        source_map_error("Flow compile option is duplicated", %{option: :source_map})

      true ->
        opts |> Keyword.get(:source_map, %{}) |> validate_source_map()
    end
  end

  defp source_map(_opts),
    do: source_map_error("Flow compile options must be a keyword list or source map")

  @doc false
  @spec validate_source_map(term()) :: {:ok, Compiled.source_map()} | {:error, Exception.t()}
  def validate_source_map(source_map) when is_map(source_map) and not is_struct(source_map) do
    Enum.reduce_while(source_map, {:ok, %{}}, fn {path, location}, {:ok, validated} ->
      with :ok <- validate_source_path(path),
           :ok <- validate_source_location(location, path) do
        {:cont, {:ok, Map.put(validated, path, location)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def validate_source_map(_source_map), do: source_map_error("Flow source map must be a map")

  defp validate_source_path(path) when is_list(path) do
    cond do
      List.improper?(path) ->
        source_map_error("Flow source-map path must be a proper list")

      Enum.all?(path, &valid_source_path_segment?/1) ->
        :ok

      true ->
        source_map_error("Flow source-map path contains an invalid segment")
    end
  end

  defp validate_source_path(_path),
    do: source_map_error("Flow source-map path must be a proper list")

  defp valid_source_path_segment?(segment) when is_binary(segment), do: String.valid?(segment)
  defp valid_source_path_segment?(segment) when is_atom(segment), do: not is_nil(segment)
  defp valid_source_path_segment?(segment) when is_integer(segment), do: segment >= 0
  defp valid_source_path_segment?(_segment), do: false

  defp validate_source_location(location, path)
       when is_map(location) and not is_struct(location) do
    unknown_keys = Map.keys(location) -- [:file, :line, :column]

    cond do
      unknown_keys != [] ->
        source_map_error("Flow source location contains an unknown field", %{
          path: path,
          field: hd(unknown_keys)
        })

      not valid_source_file?(Map.get(location, :file)) ->
        source_map_error("Flow source location file must be a valid UTF-8 string", %{path: path})

      not valid_source_position?(Map.get(location, :line)) ->
        source_map_error("Flow source location line must be a positive integer", %{path: path})

      not valid_source_position?(Map.get(location, :column)) ->
        source_map_error("Flow source location column must be a positive integer", %{path: path})

      true ->
        :ok
    end
  end

  defp validate_source_location(_location, path),
    do: source_map_error("Flow source location must be a map", %{path: path})

  defp valid_source_file?(nil), do: true
  defp valid_source_file?(file) when is_binary(file), do: String.valid?(file)
  defp valid_source_file?(_file), do: false

  defp valid_source_position?(nil), do: true
  defp valid_source_position?(value), do: is_integer(value) and value > 0

  defp source_map_error(message, details \\ %{}),
    do: {:error, Error.validation_error(message, details)}
end
