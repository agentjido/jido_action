defmodule Jido.Flow.Registry do
  @moduledoc """
  Resolves stable stored identifiers to trusted host Actions and schemas.

  A Registry is flat. Each string identifier maps to one typed entry:

      Jido.Flow.Registry.new!(%{
        "actions/send-email/v1" => {:action, MyApp.SendEmail},
        "schemas/email/v1" => {:schema, MyApp.EmailSchema.schema()}
      })

  Stored Flow data contains identifiers only. The reader resolves them through
  a Registry that the host application owns. Resolution does not create atoms
  or derive module names from stored data.
  """

  alias Jido.Action.Error

  @maximum_entries 10_000
  @identifier_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:@-]{0,254}\z/

  @type stable_id :: String.t()
  @type entry :: {:action, module()} | {:schema, term()}
  @type t :: %__MODULE__{entries: %{stable_id() => entry()}}

  @enforce_keys [:entries]
  defstruct [:entries]

  @doc "Builds and validates a flat trusted-host Registry."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{entries: entries}), do: new(entries)

  def new(%{} = entries) when map_size(entries) <= @maximum_entries do
    entries
    |> Enum.sort_by(fn {identifier, _entry} -> sort_key(identifier) end)
    |> Enum.reduce_while({:ok, %{}}, fn {identifier, entry}, {:ok, registry} ->
      with :ok <- validate_identifier(identifier),
           :ok <- validate_entry(entry) do
        {:cont, {:ok, Map.put(registry, identifier, entry)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, %__MODULE__{entries: normalized}}
      {:error, error} -> {:error, error}
    end
  end

  def new(%{} = entries) do
    error("flow registry exceeds its entry limit", %{
      entries: map_size(entries),
      maximum_entries: @maximum_entries
    })
  end

  def new(_entries), do: error("flow registry must be a map")

  @doc "Builds a Registry or raises the validation error."
  @spec new!(map() | t()) :: t() | no_return()
  def new!(entries) do
    case new(entries) do
      {:ok, registry} -> registry
      {:error, error} -> raise error
    end
  end

  @doc "Resolves one identifier of the required kind."
  @spec resolve(t(), stable_id(), :action | :schema) ::
          {:ok, module() | term()} | {:error, Exception.t()}
  def resolve(%__MODULE__{entries: entries}, identifier, kind)
      when kind in [:action, :schema] do
    with :ok <- validate_identifier(identifier) do
      case Map.fetch(entries, identifier) do
        {:ok, {^kind, value}} ->
          {:ok, value}

        {:ok, {actual_kind, _value}} ->
          error("flow registry identifier has the wrong entry kind", %{
            identifier: identifier,
            expected: kind,
            actual: actual_kind
          })

        :error ->
          error("unknown flow registry identifier", %{identifier: identifier, kind: kind})
      end
    end
  end

  @doc "Finds the one stable identifier for a trusted Action or schema value."
  @spec identifier(t(), :action | :schema, term()) ::
          {:ok, stable_id()} | {:error, Exception.t()}
  def identifier(%__MODULE__{entries: entries}, kind, value) when kind in [:action, :schema] do
    identifiers =
      for {identifier, {entry_kind, entry_value}} <- entries,
          entry_kind == kind and entry_value === value,
          do: identifier

    case Enum.sort(identifiers) do
      [identifier] ->
        {:ok, identifier}

      [] ->
        error("flow registry has no identifier for the required value", %{kind: kind})

      identifiers ->
        error("flow registry has multiple identifiers for the same value", %{
          kind: kind,
          identifiers: identifiers
        })
    end
  end

  @doc false
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(identifier) when is_binary(identifier) do
    byte_size(identifier) in 1..255 and Regex.match?(@identifier_pattern, identifier)
  end

  def valid_identifier?(_identifier), do: false

  defp validate_identifier(identifier) do
    if valid_identifier?(identifier) do
      :ok
    else
      error("invalid flow registry identifier", %{identifier: bounded_identifier(identifier)})
    end
  end

  defp validate_entry({:action, module}) when is_atom(module) and not is_nil(module), do: :ok
  defp validate_entry({:schema, _schema}), do: :ok

  defp validate_entry(entry),
    do: error("invalid flow registry entry", %{entry: entry_type(entry)})

  defp bounded_identifier(identifier) when is_binary(identifier) and byte_size(identifier) <= 255,
    do: identifier

  defp bounded_identifier(identifier) when is_binary(identifier),
    do: %{type: :binary, bytes: byte_size(identifier)}

  defp bounded_identifier(identifier), do: %{type: entry_type(identifier)}

  defp entry_type(value) when is_atom(value), do: :atom
  defp entry_type(value) when is_binary(value), do: :binary
  defp entry_type(value) when is_integer(value), do: :integer
  defp entry_type(value) when is_list(value), do: :list
  defp entry_type(value) when is_map(value), do: :map
  defp entry_type(value) when is_tuple(value), do: :tuple
  defp entry_type(_value), do: :other

  defp sort_key(identifier) when is_binary(identifier), do: {0, identifier}
  defp sort_key(identifier), do: {1, inspect(identifier)}

  defp error(message, details \\ %{}), do: {:error, Error.validation_error(message, details)}
end
