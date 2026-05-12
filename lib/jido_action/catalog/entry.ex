defmodule Jido.Action.Catalog.Entry do
  @moduledoc """
  Normalized metadata for one `Jido.Action` module in an action catalog.

  Entries are plain values. They are intended for inspection, filtering, search,
  documentation, and later projection into higher-level runtimes.
  """

  alias Jido.Action.Error
  alias Jido.Action.Schema

  @schema_kind_values [:empty, :nimble, :zoi, :json_schema, :unknown]
  @visibility_values [:public, :internal, :hidden]
  @risk_values [:low, :medium, :high]
  @source_values [:module, :runtime, :remote]
  @string_key_fields [
    :id,
    :module,
    :name,
    :title,
    :description,
    :summary,
    :namespace,
    :package,
    :version,
    :category,
    :tags,
    :capabilities,
    :input_schema,
    :output_schema,
    :schema_kind,
    :keywords,
    :examples,
    :visibility,
    :risk,
    :read_only?,
    :requires_confirmation?,
    :scopes,
    :timeout,
    :source,
    :metadata
  ]
  @enum_fields %{
    schema_kind: @schema_kind_values,
    visibility: @visibility_values,
    risk: @risk_values,
    source: @source_values
  }

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(description: "Stable catalog entry id"),
              module:
                Zoi.atom(description: "Concrete Jido.Action module")
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
                Zoi.enum(@schema_kind_values, description: "Input schema source/format")
                |> Zoi.default(:empty),
              keywords:
                Zoi.list(Zoi.string(), description: "Explicit search keywords") |> Zoi.default([]),
              examples:
                Zoi.list(Zoi.map(), description: "Small input/output examples") |> Zoi.default([]),
              visibility:
                Zoi.enum(@visibility_values,
                  description: "Visibility: :public | :internal | :hidden"
                )
                |> Zoi.default(:public),
              risk:
                Zoi.enum(@risk_values, description: "Risk level: :low | :medium | :high")
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
                Zoi.enum(@source_values,
                  description: "Registration source: :module | :runtime | :remote"
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
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    attrs =
      attrs
      |> normalize_attr_map()
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
  Builds a catalog entry from a `Jido.Action` module.

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
  @spec validate_action_module(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_action_module(module, _opts \\ [])

  def validate_action_module(module, _opts) when not is_atom(module) or is_nil(module),
    do: {:error, "must be a module atom"}

  def validate_action_module(module, _opts) do
    case Code.ensure_compiled(module) do
      {:module, _} ->
        cond do
          not action_behaviour?(module) ->
            {:error, "must use Jido.Action"}

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
          Map.get(attrs, :module, module),
          Map.get(attrs, :name),
          Map.get(attrs, :version)
        )
      )
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
    if (Map.has_key?(overrides, :input_schema) or Map.has_key?(overrides, "input_schema")) and
         not Map.has_key?(overrides, :schema_kind) and not Map.has_key?(overrides, "schema_kind") do
      Map.put(attrs, :schema_kind, Schema.schema_type(Map.get(attrs, :input_schema)))
    else
      attrs
    end
  end

  defp normalize_overrides(overrides) do
    with {:ok, overrides} <- attrs_to_map(overrides) do
      {:ok, normalize_attr_map(overrides)}
    end
  end

  defp attrs_to_map(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Map.new(attrs)}
    else
      {:error, validation_error("Invalid catalog entry overrides", :invalid_overrides)}
    end
  end

  defp attrs_to_map(%{} = attrs), do: {:ok, attrs}

  defp attrs_to_map(_attrs),
    do: {:error, validation_error("Invalid catalog entry overrides", :invalid_overrides)}

  defp normalize_attr_map(attrs) do
    attrs
    |> normalize_known_string_keys()
    |> normalize_attr_aliases()
    |> normalize_enum_values()
  end

  defp normalize_known_string_keys(attrs) do
    Enum.reduce(@string_key_fields, attrs, fn key, acc ->
      maybe_rename(acc, Atom.to_string(key), key)
    end)
  end

  defp normalize_enum_values(attrs) do
    Enum.reduce(@enum_fields, attrs, fn {field, allowed_values}, acc ->
      case Map.fetch(acc, field) do
        {:ok, value} -> Map.put(acc, field, normalize_enum_value(value, allowed_values))
        :error -> acc
      end
    end)
  end

  defp normalize_enum_value(value, allowed_values) when is_binary(value) do
    Enum.find(allowed_values, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum_value(value, _allowed_values), do: value

  defp normalize_entry_schemas(%__MODULE__{} = entry) do
    %{
      entry
      | input_schema: normalize_schema(entry.input_schema),
        output_schema: normalize_schema(entry.output_schema)
    }
  end

  defp action_behaviour?(module) do
    module
    |> module_behaviours()
    |> Enum.member?(Jido.Action)
  end

  defp module_behaviours(module) do
    attributes = module.module_info(:attributes)

    attributes
    |> Keyword.get_values(:behaviour)
    |> Kernel.++(Keyword.get_values(attributes, :behavior))
    |> List.flatten()
  end

  defp drop_nil_values(attrs) do
    Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp validation_error(message, details) do
    Error.validation_error(message, %{details: details})
  end
end
