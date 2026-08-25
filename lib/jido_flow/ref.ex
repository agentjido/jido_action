defmodule Jido.Flow.Ref do
  @moduledoc "A portable reference in a canonical Flow expression."

  alias Jido.Action
  alias Jido.Flow.Error

  @type source ::
          :input
          | :context
          | :result
          | :item
          | :item_index
          | :item_id
          | :accumulator
          | :state
          | :iteration_index
          | :body_result
  @type scope ::
          :any
          | :flow
          | :map_collection
          | :map_params
          | :reduce_collection
          | :reduce_initial
          | :reduce_params
          | :iterate_initial
          | :iterate_params
          | :iterate_update
          | :iterate_completion
  @type path :: [atom() | String.t() | non_neg_integer()]

  @schema Zoi.struct(
            __MODULE__,
            %{
              source:
                Zoi.enum(
                  [
                    :input,
                    :context,
                    :result,
                    :item,
                    :item_index,
                    :item_id,
                    :accumulator,
                    :state,
                    :iteration_index,
                    :body_result
                  ],
                  description: "Reference source"
                ),
              component: Zoi.string(description: "Result component name") |> Zoi.optional(),
              path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec input(term()) :: t()
  def input(path), do: ref(:input, nil, path)

  @spec context(term()) :: t()
  def context(path \\ nil), do: ref(:context, nil, path)

  @spec result(atom() | String.t(), term()) :: t()
  def result(component, path \\ nil), do: ref(:result, normalize_component(component), path)

  @spec item(term()) :: t()
  def item(path \\ nil), do: ref(:item, nil, path)

  @spec item_index() :: t()
  def item_index, do: ref(:item_index)

  @spec item_id() :: t()
  def item_id, do: ref(:item_id)

  @spec accumulator(term()) :: t()
  def accumulator(path \\ nil), do: ref(:accumulator, nil, path)

  @spec state(term()) :: t()
  def state(path \\ nil), do: ref(:state, nil, path)

  @spec iteration_index() :: t()
  def iteration_index, do: ref(:iteration_index)

  @spec body_result(term()) :: t()
  def body_result(path \\ nil), do: ref(:body_result, nil, path)

  @doc false
  @spec validate(t(), scope()) :: :ok | {:error, Error.InvalidDefinitionError.t()}
  def validate(ref, scope \\ :flow)

  def validate(%__MODULE__{source: source, component: component, path: path} = ref, scope) do
    with :ok <- validate_shape(source, component, path),
         :ok <- validate_scope(source, scope),
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

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ref),
    do: %{source: ref.source, component: ref.component, path: ref.path}

  @doc false
  @spec normalize_path(term()) :: path()
  def normalize_path(nil), do: []
  def normalize_path(path) when is_list(path), do: path
  def normalize_path(path), do: [path]

  defp ref(source, component \\ nil, path \\ nil) do
    %__MODULE__{source: source, component: component, path: normalize_path(path)}
  end

  defp normalize_component(component) when is_atom(component) and not is_nil(component),
    do: Atom.to_string(component)

  defp normalize_component(component) when is_binary(component), do: component

  defp validate_shape(:result, component, _path) when is_binary(component) do
    case Action.validate_name(component) do
      :ok -> :ok
      {:error, _message} -> {:error, :shape, %{source: :result}}
    end
  end

  defp validate_shape(source, nil, _path)
       when source in [:input, :context, :item, :accumulator, :state, :body_result],
       do: :ok

  defp validate_shape(source, nil, [])
       when source in [:item_index, :item_id, :iteration_index],
       do: :ok

  defp validate_shape(source, _component, _path), do: {:error, :shape, %{source: source}}

  defp validate_scope(source, _scope) when source in [:input, :context, :result], do: :ok

  defp validate_scope(_source, :any), do: :ok

  defp validate_scope(source, scope)
       when source in [:item, :item_index, :item_id] and scope in [:map_params, :reduce_params],
       do: :ok

  defp validate_scope(:accumulator, :reduce_params), do: :ok

  defp validate_scope(source, scope)
       when source in [:state, :iteration_index, :body_result] and
              scope in [:iterate_params, :iterate_update, :iterate_completion],
       do: :ok

  defp validate_scope(source, scope), do: {:error, :scope, %{source: source, scope: scope}}

  defp validate_path(path) when is_list(path) do
    case Enum.find(path, &(not valid_path_segment?(&1))) do
      nil -> :ok
      segment -> {:error, :path, %{segment: segment}}
    end
  end

  defp validate_path(path), do: {:error, :path, %{segment: path}}

  defp valid_path_segment?(segment) do
    (is_atom(segment) and not is_nil(segment)) or is_binary(segment) or
      (is_integer(segment) and segment >= 0)
  end
end
