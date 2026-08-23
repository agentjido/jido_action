defmodule Jido.Flow.State do
  @moduledoc """
  The static State contract owned by one `Jido.Flow.Iterator`.

  The Flow module DSL declares the owning node with `iterate` and its State
  contract with `state`.

  Runtime State is created for one Iterator invocation. This struct contains
  only the schema and data expressions that define that runtime value.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Element.Validation, as: ElementValidation
  alias Jido.Flow.Expression

  @version 1
  @config_keys [:version, :schema, :initial, :update]

  @type t :: %__MODULE__{
          version: 1,
          schema: term(),
          initial: term(),
          update: term()
        }

  @enforce_keys @config_keys
  defstruct @config_keys

  @doc "Builds a static Iterator State contract."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = state), do: state |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_configuration()
  end

  def new(%{} = attrs) do
    with :ok <- ElementValidation.known_keys(attrs, @config_keys, "iterator state"),
         {:ok, version} <- validate_version(Map.get(attrs, :version, @version)),
         {:ok, schema} <- validate_required_schema(attrs),
         {:ok, initial} <- validate_required_expression(attrs, :initial, :iterate_initial),
         {:ok, update} <- validate_required_expression(attrs, :update, :iterate_update) do
      {:ok,
       %__MODULE__{
         version: version,
         schema: schema,
         initial: initial,
         update: update
       }}
    end
  end

  def new(_attrs), do: invalid_configuration()

  @doc "Builds a State contract or raises on validation failure."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = state) do
    state.initial
    |> Expression.result_refs()
    |> Kernel.++(Expression.result_refs(state.update))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      kind: :iterate_state,
      version: state.version,
      schema: state.schema,
      initial: Expression.to_map(state.initial),
      update: Expression.to_map(state.update)
    }
  end

  @doc false
  @spec static_data(t()) :: map()
  def static_data(%__MODULE__{} = state) do
    %{
      kind: :iterate_state,
      version: state.version,
      schema: state.schema,
      initial: state.initial,
      update: state.update
    }
  end

  @doc false
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = state), do: static_data(state)

  defp validate_version(@version), do: {:ok, @version}

  defp validate_version(version) do
    {:error,
     Error.validation_error("unsupported iterator state version: #{inspect(version)}", %{
       version: version,
       path: [:version]
     })}
  end

  defp validate_required_schema(attrs) do
    if Map.has_key?(attrs, :schema) do
      validate_schema(Map.fetch!(attrs, :schema))
    else
      {:error, Error.validation_error("iterator state schema is required", %{path: [:schema]})}
    end
  end

  defp validate_schema(schema) do
    with :ok <- Action.validate_static_data(schema),
         :ok <- Action.validate_action_schema(schema) do
      {:ok, schema}
    else
      {:error, message} ->
        {:error,
         Error.validation_error("iterator state schema #{message}", %{
           field: :schema,
           path: [:schema]
         })}
    end
  end

  defp validate_required_expression(attrs, field, scope) do
    if Map.has_key?(attrs, field) do
      ElementValidation.expression(
        Map.fetch!(attrs, field),
        scope,
        "iterator state #{field}",
        [field]
      )
    else
      {:error, Error.validation_error("iterator state #{field} is required", %{path: [field]})}
    end
  end

  defp invalid_configuration do
    {:error,
     Error.validation_error("iterator state configuration must be a map", %{path: [:state]})}
  end
end
