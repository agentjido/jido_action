defmodule Jido.Flow.MapCodec.RecordValidator do
  @moduledoc false

  alias Jido.Flow.MapCodec.ErrorPath

  @stored_version 1
  @stored_root_keys [
    "type",
    "version",
    "name",
    "description",
    "input_schema",
    "output_schema",
    "nodes",
    "return",
    "provenance"
  ]

  @doc false
  def validate_root(map) do
    validate_record(
      map,
      @stored_root_keys,
      ["type", "version", "name", "input_schema", "output_schema", "nodes", "return"],
      :root
    )
  end

  @doc false
  def validate_root_header(map) do
    with {:ok, version} <-
           fetch_required(map, :version, "flow map version is required"),
         :ok <- validate_version(version),
         {:ok, type} <- fetch_required(map, :type, "flow map type is required") do
      validate_type(type)
    end
  end

  @doc false
  def validate_node_record(node) do
    validate_record(
      node,
      ["name", "action", "input", "deps", "provenance"],
      ["name", "action", "input", "deps"],
      :node
    )
  end

  @doc false
  def validate_choice_record(choice) do
    with :ok <-
           validate_record(
             choice,
             ["kind", "name", "options", "fallback", "deps", "provenance"],
             ["kind", "name", "options", "fallback", "deps"],
             :choice
           ) do
      validate_choice_kind(Map.fetch!(choice, "kind"))
    end
  end

  @doc false
  def validate_map_record(map) do
    validate_record(
      map,
      ["kind", "name", "collection", "action", "input", "on_error", "deps", "provenance"],
      ["kind", "name", "collection", "action", "input", "on_error", "deps"],
      :map
    )
  end

  @doc false
  def validate_reduce_record(reduce) do
    validate_record(
      reduce,
      ["kind", "name", "collection", "initial", "action", "input", "deps", "provenance"],
      ["kind", "name", "collection", "initial", "action", "input", "deps"],
      :reduce
    )
  end

  @doc false
  def validate_iterator_record(iterator) do
    validate_record(
      iterator,
      [
        "kind",
        "name",
        "action",
        "input",
        "state",
        "completion",
        "max_iterations",
        "deps",
        "provenance"
      ],
      ["kind", "name", "action", "input", "state", "completion", "max_iterations", "deps"],
      :iterate
    )
  end

  @doc false
  def validate_iterator_state_record(state) do
    validate_record(
      state,
      ["kind", "version", "schema", "initial", "update"],
      ["kind", "version", "schema", "initial", "update"],
      :iterate_state
    )
  end

  @doc false
  def validate_choice_option_record(option) do
    validate_record(
      option,
      ["name", "condition", "action", "input"],
      ["name", "condition", "action", "input"],
      :choice_option
    )
  end

  @doc false
  def validate_choice_fallback_record(fallback) do
    validate_record(
      fallback,
      ["name", "action", "input"],
      ["name", "action", "input"],
      :choice_fallback
    )
  end

  @doc false
  def validate_condition_record(condition) do
    validate_record(
      condition,
      ["operator", "operands"],
      ["operator", "operands"],
      :choice_condition
    )
  end

  @doc false
  def validate_ref_record(map, type) do
    {allowed, required} = ref_fields(type)
    validate_record(map, allowed, required, :reference)
  end

  @doc false
  def validate_node_deps(deps) when is_list(deps) do
    if List.improper?(deps) do
      ErrorPath.error("flow node deps must be a list", %{deps: inspect(deps)})
    else
      {:ok, deps}
    end
  end

  def validate_node_deps(deps),
    do: ErrorPath.error("flow node deps must be a list", %{deps: deps})

  @doc false
  def validate_record(map, allowed, required, record) do
    case map |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in allowed)) do
      nil ->
        case Enum.find(required, &(not Map.has_key?(map, &1))) do
          nil ->
            :ok

          field ->
            ErrorPath.error(
              "#{record_label(record)} is missing required field: #{inspect(field)}",
              %{record: record, field: field}
            )
        end

      field ->
        ErrorPath.error("#{record_label(record)} contains unknown field: #{inspect(field)}", %{
          record: record,
          field: field
        })
    end
  end

  @doc false
  def validate_unique_entries(entries) do
    case entries |> Enum.map(&elem(&1, 0)) |> first_duplicate() do
      nil -> {:ok, entries}
      key -> ErrorPath.error("encoded map contains a duplicate key", %{key: key})
    end
  end

  @doc false
  def first_duplicate(values) do
    values
    |> Enum.reduce_while(MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, {:duplicate, value}}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
    |> case do
      {:duplicate, value} -> value
      %MapSet{} -> nil
    end
  end

  @doc false
  def exact_fetch_required(map, field, message) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> ErrorPath.error(message)
    end
  end

  @doc false
  def fetch_required(map, field, message) do
    exact_fetch_required(map, Atom.to_string(field), message)
  end

  @doc false
  def fetch_optional(map, field, default) do
    Map.get(map, Atom.to_string(field), default)
  end

  @doc false
  def field(field), do: Atom.to_string(field)

  defp validate_version(@stored_version), do: :ok

  defp validate_version(version) do
    ErrorPath.error("unsupported flow map version: #{inspect(version)}", %{version: version})
  end

  defp validate_type("flow"), do: :ok

  defp validate_type(type) do
    ErrorPath.error("flow map type must be flow", %{type: type})
  end

  defp validate_choice_kind("choice"), do: :ok

  defp validate_choice_kind(kind) do
    ErrorPath.error("unknown flow node kind: #{inspect(kind)}", %{kind: kind})
  end

  defp ref_fields(type)
       when type in ["input", "context", "item", "accumulator", "state", "body_result"] do
    {["type", "path"], ["type", "path"]}
  end

  defp ref_fields("result") do
    {["type", "node", "path"], ["type", "node", "path"]}
  end

  defp ref_fields("value"), do: {["type", "value"], ["type", "value"]}

  defp ref_fields(type) when type in ["item_index", "item_id"] do
    {["type"], ["type"]}
  end

  defp ref_fields("iteration_index") do
    {["type", "path"], ["type", "path"]}
  end

  defp record_label(:iterate_state), do: "iterator state"
  defp record_label(record), do: to_string(record)
end
