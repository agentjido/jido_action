defmodule Jido.Authoring.Registry do
  @moduledoc """
  Stores trusted typed identifiers for portable authoring documents.

  A write entry maps one stable string identifier to a `{kind, value}` pair.
  A read alias maps an old identifier directly to one write identifier. The
  owner validates the meaning of each kind and value when it uses the entry.
  One Registry can contain kinds for more than one document owner.
  """

  @maximum_entries 10_000
  @identifier_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:@-]{0,254}\z/

  @type stable_id :: String.t()
  @type kind :: atom()
  @type write_entry :: {kind(), term()}
  @type alias_entry :: {:alias, stable_id()}
  @type entry :: write_entry() | alias_entry()
  @type write_key :: {kind(), term()}
  @type t :: %__MODULE__{
          entries: %{stable_id() => entry()},
          write_ids: %{write_key() => stable_id()}
        }

  @enforce_keys [:entries, :write_ids]
  defstruct [:entries, :write_ids]

  defmodule Error do
    @moduledoc "An invalid trusted authoring Registry or Registry operation."
    defexception [:message, details: %{}]

    @type t :: %__MODULE__{message: String.t(), details: map()}
  end

  @doc "Builds and validates a trusted typed-ID map."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{entries: entries}), do: new(entries)

  def new(entries)
      when is_map(entries) and not is_struct(entries) and map_size(entries) <= @maximum_entries do
    with {:ok, entries} <- validate_entries(entries),
         :ok <- validate_aliases(entries),
         {:ok, write_ids} <- build_write_ids(entries) do
      {:ok, %__MODULE__{entries: entries, write_ids: write_ids}}
    end
  end

  def new(entries) when is_map(entries) and not is_struct(entries) do
    error("authoring Registry exceeds its entry limit", %{
      entries: map_size(entries),
      maximum_entries: @maximum_entries
    })
  end

  def new(_entries), do: error("authoring Registry must be a map")

  @doc "Builds a Registry or raises its validation error."
  @spec new!(map() | t()) :: t() | no_return()
  def new!(entries) do
    case new(entries) do
      {:ok, registry} -> registry
      {:error, exception} -> raise exception
    end
  end

  @doc "Resolves one identifier of the required kind."
  @spec resolve(t(), stable_id(), kind()) :: {:ok, term()} | {:error, Error.t()}
  def resolve(%__MODULE__{entries: entries}, identifier, kind)
      when is_atom(kind) and kind != :alias do
    with :ok <- validate_identifier(identifier) do
      case Map.fetch(entries, identifier) do
        {:ok, {:alias, write_identifier}} ->
          resolve_write_entry(entries, write_identifier, identifier, kind)

        {:ok, entry} ->
          resolve_entry(entry, identifier, kind)

        :error ->
          error("unknown authoring Registry identifier", %{identifier: identifier, kind: kind})
      end
    end
  end

  def resolve(%__MODULE__{}, identifier, kind),
    do: error("invalid authoring Registry kind", %{identifier: identifier, kind: kind})

  @doc "Finds the canonical write identifier for one typed value."
  @spec identifier(t(), kind(), term()) :: {:ok, stable_id()} | {:error, Error.t()}
  def identifier(%__MODULE__{write_ids: write_ids}, kind, value)
      when is_atom(kind) and kind != :alias do
    case Map.fetch(write_ids, {kind, value}) do
      {:ok, identifier} ->
        {:ok, identifier}

      :error ->
        error("authoring Registry has no identifier for the required value", %{kind: kind})
    end
  end

  def identifier(%__MODULE__{}, kind, _value),
    do: error("invalid authoring Registry kind", %{kind: kind})

  defp validate_entries(entries) do
    entries
    |> Enum.sort_by(fn {identifier, _entry} -> sort_key(identifier) end)
    |> Enum.reduce_while({:ok, %{}}, fn {identifier, entry}, {:ok, validated} ->
      with :ok <- validate_identifier(identifier),
           :ok <- validate_entry(entry) do
        {:cont, {:ok, Map.put(validated, identifier, entry)}}
      else
        {:error, exception} -> {:halt, {:error, exception}}
      end
    end)
  end

  defp validate_identifier(identifier) do
    if is_binary(identifier) and byte_size(identifier) in 1..255 and
         Regex.match?(@identifier_pattern, identifier) do
      :ok
    else
      error("invalid authoring Registry identifier", %{identifier: bounded_identifier(identifier)})
    end
  end

  defp validate_entry({:alias, identifier}), do: validate_identifier(identifier)

  defp validate_entry({kind, _value}) when is_atom(kind) and kind != :alias and not is_nil(kind),
    do: :ok

  defp validate_entry(entry),
    do: error("invalid authoring Registry entry", %{entry: entry_type(entry)})

  defp validate_aliases(entries) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn
      {identifier, {:alias, write_identifier}}, :ok ->
        case Map.fetch(entries, write_identifier) do
          {:ok, {:alias, _next_identifier}} ->
            {:halt,
             error("authoring Registry alias must refer directly to a write identifier", %{
               identifier: identifier,
               write_identifier: write_identifier
             })}

          {:ok, _write_entry} ->
            {:cont, :ok}

          :error ->
            {:halt,
             error("authoring Registry alias refers to an unknown write identifier", %{
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
           error("authoring Registry has multiple write identifiers for the same value", %{
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
        error("authoring Registry alias must refer directly to a write identifier", %{
          identifier: alias_identifier,
          write_identifier: write_identifier
        })

      {:ok, entry} ->
        resolve_entry(entry, alias_identifier, kind)

      :error ->
        error("authoring Registry alias refers to an unknown write identifier", %{
          identifier: alias_identifier,
          write_identifier: write_identifier
        })
    end
  end

  defp resolve_entry({kind, value}, _identifier, kind), do: {:ok, value}

  defp resolve_entry({actual_kind, _value}, identifier, expected_kind) do
    error("authoring Registry identifier has the wrong entry kind", %{
      identifier: identifier,
      expected: expected_kind,
      actual: actual_kind
    })
  end

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

  defp error(message, details \\ %{}),
    do: {:error, Error.exception(message: message, details: details)}
end
