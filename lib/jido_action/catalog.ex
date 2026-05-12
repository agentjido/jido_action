defmodule Jido.Action.Catalog do
  @moduledoc """
  A plain value-level catalog of `Jido.Action` modules.

  This is intentionally not a process-backed registry. It gives callers a small,
  serializable structure for collecting action metadata and doing deterministic,
  LLM-free lookup and search.
  """

  alias Jido.Action.Catalog.Entry
  alias Jido.Action.Catalog.Hit
  alias Jido.Action.Catalog.Query
  alias Jido.Action.Error

  @filter_enum_values %{
    schema_kind: [:empty, :nimble, :zoi, :json_schema, :unknown],
    visibility: [:public, :internal, :hidden],
    risk: [:low, :medium, :high],
    source: [:module, :runtime]
  }

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(description: "Catalog id"),
              name: Zoi.string(description: "Human/catalog name") |> Zoi.optional(),
              description: Zoi.string(description: "Catalog description") |> Zoi.default(""),
              version: Zoi.string(description: "Catalog version") |> Zoi.optional(),
              entries:
                Zoi.map(description: "Map of entry id to Catalog.Entry") |> Zoi.default(%{}),
              metadata:
                Zoi.map(description: "Catalog-level extension metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type entry_ref :: String.t() | Entry.t()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the Zoi schema used to validate catalogs.
  """
  @spec schema() :: term()
  def schema, do: @schema

  @doc """
  Builds an empty catalog.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs \\ %{})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    attrs = Map.put_new_lazy(attrs, :id, &Uniq.UUID.uuid7/0)

    with {:ok, attrs} <- normalize_entries_attr(attrs) do
      case Zoi.parse(@schema, attrs) do
        {:ok, catalog} ->
          {:ok, catalog}

        {:error, errors} ->
          {:error, Error.validation_error("Invalid action catalog", %{details: errors})}
      end
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("Invalid action catalog")}

  @doc """
  Same as `new/1`, but raises on error.
  """
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, catalog} -> catalog
      {:error, error} -> raise error
    end
  end

  @doc """
  Builds a catalog from action modules.
  """
  @spec from_modules([module()], map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def from_modules(modules, attrs \\ []) when is_list(modules) do
    with {:ok, catalog} <- new(attrs) do
      Enum.reduce_while(modules, {:ok, catalog}, fn module, {:ok, acc} ->
        case register(acc, module) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Same as `from_modules/2`, but raises on error.
  """
  @spec from_modules!([module()], map() | keyword()) :: t() | no_return()
  def from_modules!(modules, attrs \\ []) do
    case from_modules(modules, attrs) do
      {:ok, catalog} -> catalog
      {:error, error} -> raise error
    end
  end

  @doc """
  Registers an action module or prebuilt entry in a catalog.
  """
  @spec register(t(), module() | Entry.t(), map() | keyword()) ::
          {:ok, t()} | {:error, Exception.t()}
  def register(catalog, entry, overrides \\ [])

  def register(%__MODULE__{} = catalog, %Entry{} = entry, overrides) do
    with {:ok, attrs} <- merge_entry_overrides(entry, overrides),
         {:ok, entry} <- Entry.new(attrs) do
      {:ok, put_entry(catalog, entry)}
    end
  end

  def register(%__MODULE__{} = catalog, module, overrides) when is_atom(module) do
    with {:ok, entry} <- Entry.from_module(module, overrides) do
      {:ok, put_entry(catalog, entry)}
    end
  end

  def register(_catalog, _entry, _overrides),
    do: {:error, Error.validation_error("Invalid catalog registration")}

  @doc """
  Same as `register/3`, but raises on error.
  """
  @spec register!(t(), module() | Entry.t(), map() | keyword()) :: t() | no_return()
  def register!(catalog, entry, overrides \\ []) do
    case register(catalog, entry, overrides) do
      {:ok, updated} -> updated
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns entries sorted by action name and id.
  """
  @spec list(t()) :: [Entry.t()]
  def list(%__MODULE__{} = catalog) do
    catalog.entries
    |> Map.values()
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  @doc """
  Fetches an entry by id or unique action name.
  """
  @spec fetch(t(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def fetch(%__MODULE__{} = catalog, id_or_name) when is_binary(id_or_name) do
    case Map.fetch(catalog.entries, id_or_name) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        fetch_by_name(catalog, id_or_name)
    end
  end

  @doc """
  Same as `fetch/2`, but raises on error.
  """
  @spec fetch!(t(), String.t()) :: Entry.t() | no_return()
  def fetch!(catalog, id_or_name) do
    case fetch(catalog, id_or_name) do
      {:ok, entry} ->
        entry

      {:error, reason} ->
        raise Error.validation_error("Catalog entry not found", %{reason: reason})
    end
  end

  @doc """
  Removes an entry by id, unique action name, or entry value.
  """
  @spec unregister(t(), entry_ref()) :: {:ok, t()} | {:error, term()}
  def unregister(%__MODULE__{} = catalog, %Entry{} = entry) do
    {:ok, %{catalog | entries: Map.delete(catalog.entries, entry.id)}}
  end

  def unregister(%__MODULE__{} = catalog, id_or_name) when is_binary(id_or_name) do
    with {:ok, entry} <- fetch(catalog, id_or_name) do
      unregister(catalog, entry)
    end
  end

  @doc """
  Searches entries with deterministic lexical scoring.
  """
  @spec search(t(), Query.t() | map() | keyword() | String.t()) ::
          {:ok, [Hit.t()]} | {:error, Exception.t()}
  def search(%__MODULE__{} = catalog, query_or_attrs) do
    with {:ok, query} <- Query.new(query_or_attrs) do
      hits =
        catalog
        |> entries()
        |> Enum.filter(&matches_filters?(&1, query))
        |> Enum.map(&score_entry(&1, query))
        |> Enum.reject(fn %{score: score} -> score <= 0.0 and has_text?(query) end)
        |> Enum.sort_by(fn %{score: score, entry: entry} -> {-score, entry.name, entry.id} end)
        |> Enum.take(query.limit)
        |> Enum.map(&Hit.new!/1)

      {:ok, hits}
    end
  end

  @doc """
  Same as `search/2`, but raises on error.
  """
  @spec search!(t(), Query.t() | map() | keyword() | String.t()) :: [Hit.t()] | no_return()
  def search!(catalog, query_or_attrs) do
    case search(catalog, query_or_attrs) do
      {:ok, hits} -> hits
      {:error, error} -> raise error
    end
  end

  defp put_entry(%__MODULE__{} = catalog, %Entry{} = entry) do
    %{catalog | entries: Map.put(catalog.entries, entry.id, entry)}
  end

  defp entries(%__MODULE__{} = catalog), do: Map.values(catalog.entries)

  defp merge_entry_overrides(%Entry{} = entry, overrides) do
    with {:ok, overrides} <- normalize_entry_overrides(overrides) do
      {:ok, Map.merge(Map.from_struct(entry), overrides)}
    end
  end

  defp normalize_entry_overrides(overrides) when is_list(overrides) do
    if Keyword.keyword?(overrides) do
      {:ok, Map.new(overrides)}
    else
      {:error,
       Error.validation_error("Invalid catalog registration", %{details: :invalid_overrides})}
    end
  end

  defp normalize_entry_overrides(%{} = overrides), do: {:ok, overrides}

  defp normalize_entry_overrides(_overrides),
    do:
      {:error,
       Error.validation_error("Invalid catalog registration", %{details: :invalid_overrides})}

  defp normalize_entries_attr(attrs) do
    entries = Map.get(attrs, :entries, Map.get(attrs, "entries", %{}))

    with {:ok, entries} <- normalize_entries(entries) do
      attrs =
        attrs
        |> Map.delete("entries")
        |> Map.put(:entries, entries)

      {:ok, attrs}
    end
  end

  defp normalize_entries(entries) when is_map(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_entry_value(value) do
        {:ok, entry} ->
          {:cont, {:ok, Map.put(acc, entry.id, entry)}}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.validation_error("Invalid action catalog", %{
              details: %{entries: %{key => reason}}
            })}}
      end
    end)
  end

  defp normalize_entries(_entries) do
    {:error,
     Error.validation_error("Invalid action catalog", %{
       details: %{entries: "must be a map of catalog entries"}
     })}
  end

  defp normalize_entry_value(%Entry{} = entry), do: Entry.new(Map.from_struct(entry))
  defp normalize_entry_value(%{} = attrs), do: Entry.new(attrs)
  defp normalize_entry_value(attrs) when is_list(attrs), do: Entry.new(attrs)
  defp normalize_entry_value(_attrs), do: {:error, :invalid_entry}

  defp fetch_by_name(catalog, name) do
    matches = catalog.entries |> Map.values() |> Enum.filter(&(&1.name == name))

    case matches do
      [entry] -> {:ok, entry}
      [] -> {:error, :not_found}
      entries -> {:error, {:ambiguous, name, Enum.map(entries, & &1.id)}}
    end
  end

  defp matches_filters?(%Entry{} = entry, %Query{} = query) do
    visibility_match?(entry, query.visibility) and
      optional_equal?(entry.namespace, query.namespace) and
      contains_all?(entry.tags, query.tags) and
      contains_all?(entry.capabilities, query.capabilities) and
      map_filters_match?(entry, query.filters)
  end

  defp visibility_match?(entry, visibilities), do: entry.visibility in visibilities

  defp optional_equal?(_value, nil), do: true
  defp optional_equal?(value, expected), do: value == expected

  defp contains_all?(_values, []), do: true

  defp contains_all?(values, required) do
    value_set = MapSet.new(values)
    Enum.all?(required, &MapSet.member?(value_set, &1))
  end

  defp map_filters_match?(_entry, filters) when map_size(filters) == 0, do: true

  defp map_filters_match?(entry, filters) do
    entry_attrs = Map.from_struct(entry)

    Enum.all?(filters, fn {key, expected} ->
      key = normalize_filter_key(key)

      case Map.fetch(entry_attrs, key) do
        {:ok, actual} -> actual == normalize_filter_value(key, expected)
        :error -> false
      end
    end)
  end

  defp normalize_filter_key(key) when is_atom(key), do: key

  defp normalize_filter_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_filter_value(key, value) when is_binary(value) do
    case Map.fetch(@filter_enum_values, key) do
      {:ok, allowed_values} -> Enum.find(allowed_values, value, &(Atom.to_string(&1) == value))
      :error -> value
    end
  end

  defp normalize_filter_value(_key, value), do: value

  defp has_text?(%Query{text: text}) when is_binary(text), do: String.trim(text) != ""
  defp has_text?(_query), do: false

  defp score_entry(%Entry{} = entry, %Query{} = query) do
    text = normalize_text(query.text)
    tokens = text_tokens(text)

    {score, matches} =
      [
        {:id, entry.id, 100.0, 20.0},
        {:name, entry.name, 100.0, 15.0},
        {:title, entry.title, 25.0, 8.0},
        {:summary, entry.summary, 20.0, 6.0},
        {:description, entry.description, 15.0, 5.0},
        {:category, entry.category, 12.0, 4.0},
        {:tags, entry.tags, 20.0, 8.0},
        {:capabilities, entry.capabilities, 20.0, 8.0},
        {:keywords, entry.keywords, 20.0, 8.0},
        {:schema, schema_search_text(entry), 8.0, 2.0}
      ]
      |> Enum.reduce({0.0, %{}}, fn {field, value, exact_score, token_score}, {score, matches} ->
        field_score = field_score(value, text, tokens, exact_score, token_score)

        if field_score > 0 do
          {score + field_score, Map.put(matches, field, field_score)}
        else
          {score, matches}
        end
      end)

    %{
      entry: entry,
      score: if(has_text?(query), do: score, else: 1.0),
      reason: reason_from_matches(matches),
      matches: matches
    }
  end

  defp field_score(_value, "", _tokens, _exact_score, _token_score), do: 0.0

  defp field_score(values, text, tokens, exact_score, token_score) when is_list(values) do
    values
    |> Enum.map(&field_score(&1, text, tokens, exact_score, token_score))
    |> Enum.sum()
  end

  defp field_score(value, text, tokens, exact_score, token_score) when is_binary(value) do
    normalized = normalize_text(value)

    cond do
      normalized == text -> exact_score
      String.contains?(normalized, text) -> max(token_score * 2, length(tokens) * token_score)
      true -> token_match_score(normalized, tokens, token_score)
    end
  end

  defp field_score(_value, _text, _tokens, _exact_score, _token_score), do: 0.0

  defp token_match_score(_value, [], _token_score), do: 0.0

  defp token_match_score(value, tokens, token_score) do
    matches = Enum.count(tokens, &String.contains?(value, &1))
    matches * token_score
  end

  defp schema_search_text(entry) do
    [entry.input_schema, entry.output_schema]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &inspect/1)
  end

  defp normalize_text(nil), do: ""

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.trim()
  end

  defp text_tokens(""), do: []

  defp text_tokens(text) do
    text
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp reason_from_matches(matches) when map_size(matches) == 0, do: nil

  defp reason_from_matches(matches) do
    matches
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end
end
