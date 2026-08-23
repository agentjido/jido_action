defmodule Jido.Flow.Compiler.MapResult do
  @moduledoc false

  alias Jido.Action.Output

  @keys MapSet.new([:kind, :results, :errors])
  @result_keys MapSet.new([:item_id, :index, :output])
  @error_keys MapSet.new([:item_id, :index, :error])

  @doc false
  def new(results, errors) do
    %{kind: :jido_flow_map_result, results: results, errors: errors}
  end

  @doc false
  def validate(%{kind: :jido_flow_map_result, results: results, errors: errors} = aggregate) do
    with :ok <- validate_keys(aggregate),
         :ok <- validate_records(results, errors) do
      {:ok, results, errors}
    end
  end

  def validate(_aggregate), do: {:error, []}

  defp validate_keys(aggregate) do
    if aggregate |> Map.keys() |> MapSet.new() == @keys, do: :ok, else: {:error, []}
  end

  defp validate_records(results, errors) do
    with true <- is_list(results) and not List.improper?(results),
         true <- is_list(errors) and not List.improper?(errors),
         :ok <- validate_record_list(results, :result, [:results]),
         :ok <- validate_record_list(errors, :error, [:errors]),
         :ok <- validate_record_identity(results, errors) do
      :ok
    else
      false -> {:error, []}
      {:error, path} -> {:error, path}
    end
  end

  defp validate_record_list(records, kind, root_path) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, -1}, fn {record, position}, {:ok, previous_index} ->
      case validate_record(record, kind, previous_index) do
        {:ok, index} -> {:cont, {:ok, index}}
        :error -> {:halt, {:error, root_path ++ [position]}}
      end
    end)
    |> case do
      {:ok, _last_index} -> :ok
      {:error, path} -> {:error, path}
    end
  end

  defp validate_record(record, kind, previous_index) when is_map(record) do
    index = Map.get(record, :index)

    if valid_record_keys?(record, kind) and valid_record_value?(record, kind) and
         is_integer(index) and index >= 0 and index > previous_index and
         is_binary(Map.get(record, :item_id)) do
      {:ok, index}
    else
      :error
    end
  end

  defp validate_record(_record, _kind, _previous_index), do: :error

  defp valid_record_keys?(record, :result), do: MapSet.new(Map.keys(record)) == @result_keys
  defp valid_record_keys?(record, :error), do: MapSet.new(Map.keys(record)) == @error_keys

  defp valid_record_value?(record, :result), do: valid_output?(Map.get(record, :output))
  defp valid_record_value?(record, :error), do: is_exception(Map.get(record, :error))

  defp valid_output?(%Output{} = output), do: match?({:ok, _}, Output.validate(output))
  defp valid_output?(value), do: is_map(value)

  defp validate_record_identity(results, errors) do
    records = results ++ errors
    indexes = Enum.map(records, & &1.index)
    item_ids = Enum.map(records, & &1.item_id)

    if length(Enum.uniq(indexes)) == length(indexes) and
         length(Enum.uniq(item_ids)) == length(item_ids) do
      :ok
    else
      {:error, []}
    end
  end
end
