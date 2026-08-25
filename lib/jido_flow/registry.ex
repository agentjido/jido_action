defmodule Jido.Flow.Registry do
  @moduledoc """
  Resolves stable stored identifiers to trusted host Actions, Flows, schemas,
  and data atoms.

  A Registry is flat. Each string identifier maps to one typed write entry or
  one read alias:

      Jido.Flow.Registry.new!(%{
        "actions/send-email" => {:action, MyApp.SendEmail},
        "flows/send-email" => {:flow, MyApp.SendEmailFlow},
        "actions/send-email-old" => {:alias, "actions/send-email"},
        "schemas/email" => {:schema, MyApp.EmailSchema.schema()},
        "atoms/approved" => {:atom, :approved}
      })

  A typed entry is the canonical identifier that the writer uses for its
  value. An alias is accepted only during reads and must refer directly to a
  typed entry. This permits identifier migration without making writes
  ambiguous.

  Stored Flow data contains identifiers only. The reader resolves them through
  a Registry that the host application owns. Resolution does not create atoms
  or derive module names from stored data.
  """

  alias Jido.Flow.Error

  @maximum_entries 10_000
  @identifier_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:@-]{0,254}\z/

  @type stable_id :: String.t()
  @type kind :: :action | :flow | :schema | :atom
  @type write_entry ::
          {:action, module()} | {:flow, module()} | {:schema, term()} | {:atom, atom()}
  @type alias_entry :: {:alias, stable_id()}
  @type entry :: write_entry() | alias_entry()
  @type write_key :: {kind(), term()}
  @type t :: %__MODULE__{
          entries: %{stable_id() => entry()},
          write_ids: %{write_key() => stable_id()}
        }

  @enforce_keys [:entries, :write_ids]
  defstruct [:entries, :write_ids]

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
      {:ok, normalized} -> build_registry(normalized)
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
  @spec resolve(t(), stable_id(), kind()) ::
          {:ok, module() | term()} | {:error, Exception.t()}
  def resolve(%__MODULE__{entries: entries}, identifier, kind)
      when kind in [:action, :flow, :schema, :atom] do
    with :ok <- validate_identifier(identifier) do
      case Map.fetch(entries, identifier) do
        {:ok, {:alias, write_identifier}} ->
          resolve_write_entry(entries, write_identifier, identifier, kind)

        {:ok, entry} ->
          resolve_entry(entry, identifier, kind)

        :error ->
          error("unknown flow registry identifier", %{identifier: identifier, kind: kind})
      end
    end
  end

  @doc "Finds the canonical write identifier for a trusted Action, schema, or atom value."
  @spec identifier(t(), kind(), term()) ::
          {:ok, stable_id()} | {:error, Exception.t()}
  def identifier(%__MODULE__{write_ids: write_ids}, kind, value)
      when kind in [:action, :flow, :schema, :atom] do
    case Map.fetch(write_ids, {kind, value}) do
      {:ok, identifier} ->
        {:ok, identifier}

      :error ->
        error("flow registry has no identifier for the required value", %{kind: kind})
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
  defp validate_entry({:flow, module}) when is_atom(module) and not is_nil(module), do: :ok
  defp validate_entry({:schema, _schema}), do: :ok
  defp validate_entry({:atom, atom}) when is_atom(atom), do: :ok

  defp validate_entry({:alias, identifier}), do: validate_identifier(identifier)

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

  defp build_registry(entries) do
    with :ok <- validate_aliases(entries),
         {:ok, write_ids} <- build_write_ids(entries) do
      {:ok, %__MODULE__{entries: entries, write_ids: write_ids}}
    end
  end

  defp validate_aliases(entries) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn
      {identifier, {:alias, write_identifier}}, :ok ->
        case Map.fetch(entries, write_identifier) do
          {:ok, {:alias, _next_identifier}} ->
            {:halt,
             error("flow registry alias must refer directly to a write identifier", %{
               identifier: identifier,
               write_identifier: write_identifier
             })}

          {:ok, _write_entry} ->
            {:cont, :ok}

          :error ->
            {:halt,
             error("flow registry alias refers to an unknown write identifier", %{
               identifier: identifier,
               write_identifier: write_identifier
             })}
        end

      {_identifier, _write_entry}, :ok ->
        {:cont, :ok}
    end)
  end

  defp build_write_ids(entries) do
    entries
    |> Enum.reject(&match?({_identifier, {:alias, _write_identifier}}, &1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {identifier, {kind, value}}, {:ok, write_ids} ->
      key = {kind, value}

      case Map.fetch(write_ids, key) do
        {:ok, existing_identifier} ->
          {:halt,
           error("flow registry has multiple write identifiers for the same value", %{
             kind: kind,
             identifiers: [existing_identifier, identifier]
           })}

        :error ->
          {:cont, {:ok, Map.put(write_ids, key, identifier)}}
      end
    end)
  end

  defp resolve_write_entry(entries, write_identifier, alias_identifier, kind) do
    case Map.fetch(entries, write_identifier) do
      {:ok, {:alias, _next_identifier}} ->
        error("flow registry alias must refer directly to a write identifier", %{
          identifier: alias_identifier,
          write_identifier: write_identifier
        })

      {:ok, entry} ->
        resolve_entry(entry, alias_identifier, kind)

      :error ->
        error("flow registry alias refers to an unknown write identifier", %{
          identifier: alias_identifier,
          write_identifier: write_identifier
        })
    end
  end

  defp resolve_entry({kind, value}, _identifier, kind), do: {:ok, value}

  defp resolve_entry({actual_kind, _value}, identifier, expected_kind) do
    error("flow registry identifier has the wrong entry kind", %{
      identifier: identifier,
      expected: expected_kind,
      actual: actual_kind
    })
  end

  defp error(message, details \\ %{}), do: {:error, Error.validation_error(message, details)}
end
