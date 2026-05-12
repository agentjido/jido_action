defmodule Jido.Action.Catalog.Entry do
  @moduledoc """
  Normalized metadata for one `Jido.Action` module in an action catalog.

  Entries are plain values. They are intended for inspection, filtering, search,
  documentation, and later projection into higher-level runtimes.
  """

  alias Jido.Action.Error
  alias Jido.Action.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(description: "Stable catalog entry id"),
              module: Zoi.atom(description: "Concrete Jido.Action module"),
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
                Zoi.atom(description: "Input schema source/format") |> Zoi.default(:empty),
              keywords:
                Zoi.list(Zoi.string(), description: "Explicit search keywords") |> Zoi.default([]),
              examples:
                Zoi.list(Zoi.map(), description: "Small input/output examples") |> Zoi.default([]),
              visibility:
                Zoi.atom(description: "Visibility: :public | :internal | :hidden")
                |> Zoi.default(:public),
              risk:
                Zoi.atom(description: "Risk level: :low | :medium | :high") |> Zoi.default(:low),
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
                Zoi.atom(description: "Registration source: :module | :runtime | :remote")
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
      |> normalize_attr_aliases()
      |> drop_nil_values()

    case Zoi.parse(@schema, attrs) do
      {:ok, entry} -> {:ok, entry}
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
  def from_module(module, overrides \\ []) when is_atom(module) do
    overrides = normalize_attrs(overrides)

    with :ok <- validate_action_module(module),
         {:ok, attrs} <- module_attrs(module) do
      attrs
      |> Map.merge(overrides)
      |> new()
    end
  end

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

  defp validate_action_module(module) do
    case Code.ensure_compiled(module) do
      {:module, _} ->
        cond do
          not function_exported?(module, :name, 0) ->
            {:error,
             validation_error("Invalid catalog action module", %{
               module: module,
               reason: :missing_name
             })}

          not function_exported?(module, :schema, 0) ->
            {:error,
             validation_error("Invalid catalog action module", %{
               module: module,
               reason: :missing_schema
             })}

          true ->
            :ok
        end

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

  defp stringify_json_schema(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_json_schema(value), do: value

  defp stringify_json_schema_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_json_schema_key(key), do: key

  defp stable_id(module, name, nil), do: "#{inspect(module)}:#{name}"
  defp stable_id(module, name, version), do: "#{inspect(module)}:#{name}@#{version}"

  defp normalize_attr_aliases(attrs) do
    attrs
    |> maybe_rename(:vsn, :version)
    |> maybe_rename(:schema, :input_schema)
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

  defp normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize_attrs(%{} = attrs), do: attrs
  defp normalize_attrs(_attrs), do: %{}

  defp drop_nil_values(attrs) do
    Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp validation_error(message, details) do
    Error.validation_error(message, %{details: details})
  end
end
