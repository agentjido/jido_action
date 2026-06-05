defmodule Jido.Action.Catalog.Entry do
  @moduledoc """
  Normalized metadata for one local action-compatible module in an action catalog.

  Entries are plain values. They provide a consistent data shape for action
  metadata, schemas, descriptive hints, documentation, and later projection into
  higher-level runtimes.

  Fields such as `:visibility`, `:risk`, `:read_only?`, and `:scopes` are
  descriptive metadata only. The catalog layer does not enforce policy or
  execute actions.

  A module is action-compatible when it is available locally and exports
  `name/0`, `schema/0`, and `run/2`. Catalogs do not support remote entries whose
  implementation is not loaded in the current runtime.
  """

  alias Jido.Action.Error
  alias Jido.Action.Schema

  @schema_kind_values [:empty, :nimble, :zoi, :json_schema, :unknown]
  @visibility_values [:public, :internal, :hidden]
  @risk_values [:low, :medium, :high]
  @source_values [:module, :runtime]
  @schema_kind_enum Enum.map(@schema_kind_values, &{&1, Atom.to_string(&1)})
  @visibility_enum Enum.map(@visibility_values, &{&1, Atom.to_string(&1)})
  @risk_enum Enum.map(@risk_values, &{&1, Atom.to_string(&1)})
  @source_enum Enum.map(@source_values, &{&1, Atom.to_string(&1)})

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(description: "Stable catalog entry id"),
              module:
                Zoi.union(
                  [
                    Zoi.atom(),
                    Zoi.string()
                  ],
                  description: "Concrete local action-compatible module"
                )
                |> Zoi.transform({__MODULE__, :normalize_action_module, []})
                |> Zoi.refine({__MODULE__, :validate_action_module, []}),
              name: Zoi.string(description: "Machine-friendly action name"),
              title: Zoi.string(description: "Short human label") |> Zoi.optional(),
              description:
                Zoi.string(description: "Human-readable action description") |> Zoi.default(""),
              summary:
                Zoi.string(description: "One-line search/display summary") |> Zoi.optional(),
              namespace:
                Zoi.string(description: "Logical namespace, e.g. billing.crm")
                |> Zoi.optional(),
              package: Zoi.string(description: "Owning package/application") |> Zoi.optional(),
              version: Zoi.string(description: "Action or metadata version") |> Zoi.optional(),
              category: Zoi.string(description: "Primary category") |> Zoi.optional(),
              tags: Zoi.list(Zoi.string(), description: "Search/filter tags") |> Zoi.default([]),
              capabilities:
                Zoi.list(Zoi.string(), description: "Capability labels") |> Zoi.default([]),
              input_schema: Zoi.any(description: "Normalized input schema") |> Zoi.optional(),
              output_schema: Zoi.any(description: "Normalized output schema") |> Zoi.optional(),
              schema_kind:
                Zoi.enum(@schema_kind_enum,
                  description: "Input schema source/format",
                  coerce: true
                )
                |> Zoi.default(:empty),
              keywords:
                Zoi.list(Zoi.string(), description: "Explicit search keywords") |> Zoi.default([]),
              examples:
                Zoi.list(Zoi.map(), description: "Small input/output examples") |> Zoi.default([]),
              visibility:
                Zoi.enum(@visibility_enum,
                  description: "Visibility: :public | :internal | :hidden",
                  coerce: true
                )
                |> Zoi.default(:public),
              risk:
                Zoi.enum(@risk_enum,
                  description: "Risk level: :low | :medium | :high",
                  coerce: true
                )
                |> Zoi.default(:low),
              read_only?:
                Zoi.boolean(description: "Whether execution is read-only") |> Zoi.default(false),
              requires_confirmation?:
                Zoi.boolean(description: "Whether execution should require confirmation")
                |> Zoi.default(false),
              scopes:
                Zoi.list(Zoi.string(), description: "Required auth/policy scopes")
                |> Zoi.default([]),
              timeout:
                Zoi.integer(description: "Default execution timeout in ms")
                |> Zoi.min(0)
                |> Zoi.optional(),
              source:
                Zoi.enum(@source_enum,
                  description: "Registration source: :module | :runtime",
                  coerce: true
                )
                |> Zoi.default(:module),
              metadata: Zoi.map(description: "Arbitrary extension metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the Zoi schema used to validate catalog entries.
  """
  @spec schema() :: term()
  def schema, do: @schema

  @doc """
  Builds a catalog entry from raw attributes.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}

  def new(attrs) when is_list(attrs) do
    with {:ok, attrs} <- attrs_to_map(attrs, "Invalid catalog entry", :invalid_attrs) do
      new(attrs)
    end
  end

  def new(%{} = attrs) do
    attrs =
      attrs
      |> normalize_attr_aliases()
      |> drop_nil_values()

    case Zoi.parse(@schema, attrs) do
      {:ok, entry} -> {:ok, normalize_entry_schemas(entry)}
      {:error, errors} -> {:error, validation_error("Invalid catalog entry", errors)}
    end
  end

  def new(_attrs), do: {:error, validation_error("Invalid catalog entry", :invalid_attrs)}

  @doc """
  Same as `new/1`, but raises on error.
  """
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, entry} -> entry
      {:error, error} -> raise error
    end
  end

  @doc """
  Builds a catalog entry from a local action-compatible module.

  Optional attributes override the module-derived metadata.
  """
  @spec from_module(module(), map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def from_module(module, overrides \\ [])

  def from_module(module, overrides) when is_atom(module) do
    with {:ok, overrides} <- normalize_overrides(overrides),
         :ok <- ensure_action_module(module),
         {:ok, attrs} <- module_attrs(module) do
      attrs
      |> Map.merge(overrides)
      |> refresh_derived_id(module, overrides)
      |> refresh_derived_schema_kind(overrides)
      |> new()
    end
  end

  def from_module(_module, _overrides),
    do: {:error, validation_error("Invalid catalog action module", :invalid_module)}

  @doc """
  Same as `from_module/2`, but raises on error.
  """
  @spec from_module!(module(), map() | keyword()) :: t() | no_return()
  def from_module!(module, overrides \\ []) do
    case from_module(module, overrides) do
      {:ok, entry} -> entry
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec normalize_action_module(term(), keyword()) :: {:ok, term()}
  def normalize_action_module(module, _opts \\ [])

  def normalize_action_module(module, _opts) when is_binary(module) do
    case existing_module_atom(module) do
      {:ok, module} -> {:ok, module}
      :error -> {:ok, module}
    end
  end

  def normalize_action_module(module, _opts), do: {:ok, module}

  @doc false
  @spec apply_overrides(t(), map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def apply_overrides(%__MODULE__{} = entry, overrides) do
    with {:ok, overrides} <- normalize_overrides(overrides) do
      entry
      |> Map.from_struct()
      |> Map.merge(overrides)
      |> refresh_overridden_id(entry, overrides)
      |> refresh_derived_schema_kind(overrides)
      |> new()
    end
  end

  @doc false
  @spec validate_action_module(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_action_module(module, _opts \\ [])

  def validate_action_module(module, _opts) when not is_atom(module) or is_nil(module),
    do: {:error, "must be a module atom"}

  def validate_action_module(module, _opts) do
    case Code.ensure_compiled(module) do
      {:module, _} ->
        cond do
          not function_exported?(module, :name, 0) ->
            {:error, "must export name/0"}

          not function_exported?(module, :schema, 0) ->
            {:error, "must export schema/0"}

          not function_exported?(module, :run, 2) ->
            {:error, "must export run/2"}

          true ->
            :ok
        end

      {:error, reason} ->
        {:error, "could not compile module: #{inspect(reason)}"}
    end
  end

  defp ensure_action_module(module) do
    case validate_action_module(module) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         validation_error("Invalid catalog action module", %{module: module, reason: reason})}
    end
  end

  defp module_attrs(module) do
    input_schema = module.schema()
    output_schema = safe_call(module, :output_schema, [])
    version = safe_call(module, :vsn, nil)
    name = module.name()

    attrs =
      %{
        id: stable_id(module, name, version),
        module: module,
        name: name,
        description: safe_call(module, :description, "") || "",
        category: safe_call(module, :category, nil),
        tags: safe_call(module, :tags, []) || [],
        version: version,
        input_schema: normalize_schema(input_schema),
        output_schema: normalize_schema(output_schema),
        schema_kind: Schema.schema_type(input_schema),
        source: :module
      }
      |> drop_nil_values()

    {:ok, attrs}
  rescue
    exception ->
      {:error,
       validation_error("Invalid catalog action metadata", %{
         module: module,
         exception: exception
       })}
  end

  defp safe_call(module, function, default) do
    if function_exported?(module, function, 0), do: apply(module, function, []), else: default
  end

  defp normalize_schema(nil), do: nil

  defp normalize_schema(schema) do
    Schema.to_json_schema(schema, strict: true)
    |> stringify_json_schema()
  rescue
    _ -> schema
  end

  defp stringify_json_schema(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {stringify_json_schema_key(key), stringify_json_schema(nested)}
    end)
  end

  defp stringify_json_schema(value) when is_list(value),
    do: Enum.map(value, &stringify_json_schema/1)

  defp stringify_json_schema(value) when is_boolean(value), do: value
  defp stringify_json_schema(nil), do: nil
  defp stringify_json_schema(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_json_schema(value), do: value

  defp stringify_json_schema_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_json_schema_key(key), do: key

  defp stable_id(module, name, nil), do: "#{inspect(module)}:#{name}"
  defp stable_id(module, name, version), do: "#{inspect(module)}:#{name}@#{version}"

  defp refresh_derived_id(attrs, module, overrides) do
    if Map.has_key?(overrides, :id) or Map.has_key?(overrides, "id") do
      attrs
    else
      attrs
      |> Map.put(
        :id,
        stable_id(
          attr(attrs, :module) || module,
          attr(attrs, :name),
          attr(attrs, :version)
        )
      )
    end
  end

  defp refresh_overridden_id(attrs, %__MODULE__{} = entry, overrides) do
    cond do
      Map.has_key?(overrides, :id) or Map.has_key?(overrides, "id") ->
        attrs

      entry.id == stable_id(entry.module, entry.name, entry.version) ->
        refresh_derived_id(attrs, entry.module, overrides)

      true ->
        attrs
    end
  end

  defp normalize_attr_aliases(attrs) do
    attrs
    |> maybe_rename(:vsn, :version)
    |> maybe_rename("vsn", :version)
    |> maybe_rename(:schema, :input_schema)
    |> maybe_rename("schema", :input_schema)
  end

  defp maybe_rename(attrs, from, to) do
    case Map.fetch(attrs, from) do
      {:ok, value} ->
        attrs
        |> Map.delete(from)
        |> Map.put_new(to, value)

      :error ->
        attrs
    end
  end

  defp refresh_derived_schema_kind(attrs, overrides) do
    if attr?(overrides, :input_schema) and not attr?(overrides, :schema_kind) do
      Map.put(attrs, :schema_kind, Schema.schema_type(attr(attrs, :input_schema)))
    else
      attrs
    end
  end

  defp normalize_overrides(overrides) do
    with {:ok, overrides} <- attrs_to_map(overrides) do
      {:ok, normalize_attr_aliases(overrides)}
    end
  end

  defp attrs_to_map(attrs) do
    attrs_to_map(attrs, "Invalid catalog entry overrides", :invalid_overrides)
  end

  defp attrs_to_map(attrs, message, details) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Map.new(attrs)}
    else
      {:error, validation_error(message, details)}
    end
  end

  defp attrs_to_map(%{} = attrs, _message, _details), do: {:ok, attrs}

  defp attrs_to_map(_attrs, message, details),
    do: {:error, validation_error(message, details)}

  defp existing_module_atom(module) do
    candidates =
      case String.starts_with?(module, "Elixir.") do
        true -> [module]
        false -> [module, "Elixir." <> module]
      end

    Enum.find_value(candidates, :error, fn candidate ->
      try do
        {:ok, String.to_existing_atom(candidate)}
      rescue
        ArgumentError -> false
      end
    end)
  end

  defp attr(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp normalize_entry_schemas(%__MODULE__{} = entry) do
    %{
      entry
      | input_schema: normalize_schema(entry.input_schema),
        output_schema: normalize_schema(entry.output_schema)
    }
  end

  defp drop_nil_values(attrs) do
    Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp validation_error(message, details) do
    Error.validation_error(message, %{details: details})
  end
end
