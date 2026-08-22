defmodule Jido.Flow.Ref do
  @moduledoc """
  References used by the canonical Flow IR.

  Refs are data only. They identify values from the Flow input, runtime context,
  literal values, results produced by named Flow nodes, scoped Map and Reduce
  data, or scoped Iterator State.
  """

  alias Jido.Action
  alias Jido.Action.Error

  @type kind ::
          :input
          | :context
          | :result
          | :value
          | :item
          | :item_index
          | :item_id
          | :accumulator
          | :state
          | :iteration_index
          | :body_result
  @type scope ::
          :flow
          | :map_collection
          | :map_input
          | :reduce_collection
          | :reduce_initial
          | :reduce_input
          | :iterate_initial
          | :iterate_input
          | :iterate_update
          | :iterate_completion
  @type node_name :: String.t()
  @type path :: [atom() | String.t() | integer()]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type:
                Zoi.enum(
                  [
                    :input,
                    :context,
                    :result,
                    :value,
                    :item,
                    :item_index,
                    :item_id,
                    :accumulator,
                    :state,
                    :iteration_index,
                    :body_result
                  ],
                  description: "Reference type"
                ),
              node: Zoi.string(description: "Result node name") |> Zoi.optional(),
              path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([]),
              value: Zoi.any(description: "Literal value") |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Builds a reference to a value in the Flow input.
  """
  @spec input(atom() | String.t() | integer() | list()) :: t()
  def input(path), do: %__MODULE__{type: :input, path: normalize_path(path)}

  @doc """
  Builds a reference to a value in the runtime Flow context.
  """
  @spec context(atom() | String.t() | integer() | list() | nil) :: t()
  def context(path), do: %__MODULE__{type: :context, path: normalize_path(path)}

  @doc """
  Builds a reference to a named node result.
  """
  @spec result(atom() | String.t(), atom() | String.t() | integer() | list()) :: t()
  def result(node, path \\ []) do
    %__MODULE__{type: :result, node: normalize_node_name(node), path: normalize_path(path)}
  end

  @doc """
  Wraps a literal value as a Flow expression.
  """
  @spec value(term()) :: t()
  def value(value), do: %__MODULE__{type: :value, value: value}

  @doc """
  Builds a scoped reference to the current Map or Reduce item.
  """
  @spec item(atom() | String.t() | integer() | list() | nil) :: t()
  def item(path \\ nil), do: %__MODULE__{type: :item, path: normalize_path(path)}

  @doc """
  Builds a scoped reference to the current zero-based item index.
  """
  @spec item_index() :: t()
  def item_index, do: %__MODULE__{type: :item_index}

  @doc """
  Builds a scoped reference to the current stable item identity.
  """
  @spec item_id() :: t()
  def item_id, do: %__MODULE__{type: :item_id}

  @doc """
  Builds a scoped reference to the current Reduce accumulator.
  """
  @spec accumulator(atom() | String.t() | integer() | list() | nil) :: t()
  def accumulator(path \\ nil),
    do: %__MODULE__{type: :accumulator, path: normalize_path(path)}

  @doc "Builds a scoped reference to the current Iterator State."
  @spec state(atom() | String.t() | integer() | list() | nil) :: t()
  def state(path \\ nil), do: %__MODULE__{type: :state, path: normalize_path(path)}

  @doc "Builds a scoped reference to the current zero-based Iterator iteration index."
  @spec iteration_index() :: t()
  def iteration_index, do: %__MODULE__{type: :iteration_index}

  @doc "Builds a scoped reference to the latest valid Iterator body result."
  @spec body_result(atom() | String.t() | integer() | list() | nil) :: t()
  def body_result(path \\ nil),
    do: %__MODULE__{type: :body_result, path: normalize_path(path)}

  @doc false
  @spec validate(t(), scope()) :: :ok | {:error, Error.InvalidInputError.t()}
  def validate(ref, scope \\ :flow)

  def validate(%__MODULE__{type: type, path: path, node: node, value: value} = ref, scope) do
    with :ok <- validate_shape(type, node, path, value),
         :ok <- validate_scope(type, scope),
         :ok <- validate_path(path) do
      :ok
    else
      {:error, reason, details} ->
        {:error,
         Error.validation_error(
           "invalid flow ref",
           Map.merge(%{ref: ref, reason: reason}, details)
         )}
    end
  end

  defp validate_shape(type, nil, _path, nil) when type in [:input, :context], do: :ok

  defp validate_shape(:result, node, _path, nil) when is_binary(node) do
    case Action.validate_name(node) do
      :ok -> :ok
      {:error, _message} -> {:error, :shape, %{type: :result}}
    end
  end

  defp validate_shape(:value, nil, [], _value), do: :ok

  defp validate_shape(type, nil, _path, nil)
       when type in [:item, :accumulator, :state, :body_result],
       do: :ok

  defp validate_shape(type, nil, [], nil)
       when type in [:item_index, :item_id, :iteration_index],
       do: :ok

  defp validate_shape(type, _node, _path, _value), do: {:error, :shape, %{type: type}}

  defp validate_scope(type, _scope) when type in [:input, :context, :result, :value], do: :ok

  defp validate_scope(type, scope)
       when type in [:item, :item_index, :item_id] and scope in [:map_input, :reduce_input],
       do: :ok

  defp validate_scope(:accumulator, :reduce_input), do: :ok

  defp validate_scope(type, scope)
       when type in [:state, :iteration_index, :body_result] and
              scope in [:iterate_input, :iterate_update, :iterate_completion],
       do: :ok

  defp validate_scope(type, scope), do: {:error, :scope, %{type: type, scope: scope}}

  defp validate_path([]), do: :ok

  defp validate_path([segment | path]) do
    if valid_path_segment?(segment) do
      validate_path(path)
    else
      {:error, :path, %{segment: segment}}
    end
  end

  defp validate_path(path), do: {:error, :path, %{segment: path}}

  defp valid_path_segment?(segment) do
    (is_atom(segment) and not is_nil(segment)) or is_binary(segment) or is_integer(segment)
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{type: :input, path: path}), do: %{type: :input, path: path}

  def to_map(%__MODULE__{type: :context, path: path}), do: %{type: :context, path: path}

  def to_map(%__MODULE__{type: :result, node: node, path: path}) do
    %{type: :result, node: node, path: path}
  end

  def to_map(%__MODULE__{type: :value, value: value}), do: %{type: :value, value: value}

  def to_map(%__MODULE__{type: type, path: path})
      when type in [:item, :accumulator, :state, :body_result] do
    %{type: type, path: path}
  end

  def to_map(%__MODULE__{type: type}) when type in [:item_index, :item_id],
    do: %{type: type}

  def to_map(%__MODULE__{type: :iteration_index}),
    do: %{type: :iteration_index, path: []}

  @doc false
  @spec normalize_path(atom() | String.t() | integer() | list() | nil) :: path()
  def normalize_path(nil), do: []
  def normalize_path(path) when is_list(path), do: path
  def normalize_path(path), do: [path]

  defp normalize_node_name(node) when is_atom(node) and not is_nil(node), do: Atom.to_string(node)
  defp normalize_node_name(node) when is_binary(node), do: node
end
