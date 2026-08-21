defmodule Jido.Flow.ContractBundle do
  @moduledoc """
  Trusted host data used to resolve portable stored Flow contracts.

  A contract bundle is not part of a canonical `Jido.Flow` value. It provides
  stable transport identifiers for schemas and Action registries at the stored
  map boundary.
  """

  alias Jido.Action.Error

  @fields [:id, :schemas, :action_registries]
  @identifier_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:@-]{0,254}\z/

  @enforce_keys @fields
  defstruct @fields

  @type stable_id :: String.t()
  @type action_registry :: %{stable_id() => module()}
  @type t :: %__MODULE__{
          id: stable_id(),
          schemas: %{stable_id() => term()},
          action_registries: %{stable_id() => action_registry()}
        }

  @doc "Builds and validates a trusted host contract bundle."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = bundle), do: bundle |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: invalid_attributes()
  end

  def new(%{} = attrs) do
    with :ok <- validate_record(attrs),
         :ok <- validate_identifier(Map.fetch!(attrs, :id), :id, [:id]),
         {:ok, schemas} <- validate_schemas(Map.fetch!(attrs, :schemas)),
         {:ok, registries} <-
           validate_action_registries(Map.fetch!(attrs, :action_registries)) do
      {:ok,
       %__MODULE__{
         id: Map.fetch!(attrs, :id),
         schemas: schemas,
         action_registries: registries
       }}
    end
  end

  def new(_attrs), do: invalid_attributes()

  @doc "Builds a contract bundle or raises the validation error."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, bundle} -> bundle
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(identifier) when is_binary(identifier) do
    byte_size(identifier) in 1..255 and Regex.match?(@identifier_pattern, identifier)
  end

  def valid_identifier?(_identifier), do: false

  @doc false
  @spec validate_identifier(term(), atom(), list()) :: :ok | {:error, Exception.t()}
  def validate_identifier(identifier, field, path) do
    if valid_identifier?(identifier) do
      :ok
    else
      error("invalid flow contract identifier", %{
        field: field,
        value: bounded_identifier(identifier),
        path: path
      })
    end
  end

  @doc false
  @spec normalize_collection(term()) ::
          {:ok, %{stable_id() => t()}} | {:error, Exception.t()}
  def normalize_collection(%{} = bundles) do
    bundles
    |> Enum.sort_by(fn {key, _bundle} -> identifier_sort_key(key) end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, %__MODULE__{} = bundle}, {:ok, acc} ->
        with :ok <- validate_collection_key(key),
             :ok <- validate_collection_match(key, bundle.id),
             {:ok, bundle} <- new(bundle) do
          {:cont, {:ok, Map.put(acc, key, bundle)}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end

      {_key, _bundle}, {:ok, _acc} ->
        {:halt, invalid_collection()}
    end)
  end

  def normalize_collection(_bundles), do: invalid_collection()

  defp validate_record(attrs) do
    case attrs |> Map.keys() |> Enum.sort() |> Enum.find(&(&1 not in @fields)) do
      nil ->
        case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
          nil -> :ok
          field -> record_error(:missing, field)
        end

      field ->
        record_error(:unknown, field)
    end
  end

  defp validate_schemas(%{} = schemas) do
    schemas
    |> Enum.sort_by(fn {key, _schema} -> identifier_sort_key(key) end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {identifier, schema}, {:ok, acc} when is_binary(identifier) ->
        case validate_identifier(identifier, :schemas, [:schemas, identifier]) do
          :ok -> {:cont, {:ok, Map.put(acc, identifier, schema)}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {_identifier, _schema}, {:ok, _acc} ->
        {:halt,
         error("flow contract bundle schemas must map stable identifiers to schema terms", %{
           field: :schemas
         })}
    end)
  end

  defp validate_schemas(_schemas) do
    error("flow contract bundle schemas must map stable identifiers to schema terms", %{
      field: :schemas
    })
  end

  defp validate_action_registries(%{} = registries) do
    registries
    |> Enum.sort_by(fn {key, _registry} -> identifier_sort_key(key) end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {identifier, registry}, {:ok, acc} when is_binary(identifier) ->
        with :ok <-
               validate_identifier(
                 identifier,
                 :action_registries,
                 [:action_registries, identifier]
               ),
             {:ok, registry} <- validate_action_registry(registry) do
          {:cont, {:ok, Map.put(acc, identifier, registry)}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end

      {_identifier, _registry}, {:ok, _acc} ->
        {:halt, invalid_registry_index()}
    end)
  end

  defp validate_action_registries(_registries), do: invalid_registry_index()

  defp validate_action_registry(%{} = registry) do
    registry
    |> Enum.sort_by(fn {key, _action} -> identifier_sort_key(key) end)
    |> Enum.reduce_while({:ok, %{}}, fn
      {identifier, action}, {:ok, acc}
      when is_binary(identifier) and is_atom(action) and not is_nil(action) ->
        case validate_identifier(
               identifier,
               :action_registries,
               [:action_registries, identifier]
             ) do
          :ok -> {:cont, {:ok, Map.put(acc, identifier, action)}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {_identifier, _action}, {:ok, _acc} ->
        {:halt, invalid_registry_index()}
    end)
  end

  defp validate_action_registry(_registry), do: invalid_registry_index()

  defp validate_collection_key(key) do
    if valid_identifier?(key), do: :ok, else: invalid_collection()
  end

  defp validate_collection_match(key, id) when key == id, do: :ok

  defp validate_collection_match(key, id) do
    error("flow contract bundle key does not match bundle identifier", %{
      key: key,
      bundle: id
    })
  end

  defp record_error(:missing, field) do
    error("contract_bundle is missing required field: #{inspect(field)}", %{
      record: :contract_bundle,
      field: field
    })
  end

  defp record_error(:unknown, field) do
    error("contract_bundle contains unknown field: #{inspect(field)}", %{
      record: :contract_bundle,
      field: field
    })
  end

  defp invalid_attributes do
    error("flow contract bundle attributes must be a map or keyword list", %{
      record: :contract_bundle
    })
  end

  defp invalid_collection do
    error("flow contract bundles must map stable bundle identifiers to ContractBundle structs", %{
      field: :contract_bundles
    })
  end

  defp invalid_registry_index do
    error(
      "flow contract bundle action_registries must map stable identifiers to Action registries",
      %{field: :action_registries}
    )
  end

  defp bounded_identifier(identifier) when is_binary(identifier) do
    if byte_size(identifier) <= 255 do
      identifier
    else
      %{type: :binary, bytes: byte_size(identifier)}
    end
  end

  defp bounded_identifier(identifier) do
    %{type: identifier_type(identifier)}
  end

  defp identifier_type(value) when is_atom(value), do: :atom
  defp identifier_type(value) when is_integer(value), do: :integer
  defp identifier_type(value) when is_float(value), do: :float
  defp identifier_type(value) when is_list(value), do: :list
  defp identifier_type(value) when is_map(value), do: :map
  defp identifier_type(value) when is_tuple(value), do: :tuple
  defp identifier_type(_value), do: :other

  defp identifier_sort_key(identifier) when is_binary(identifier), do: {0, identifier}
  defp identifier_sort_key(identifier), do: {1, inspect(identifier)}

  defp error(message, details), do: {:error, Error.validation_error(message, details)}
end
