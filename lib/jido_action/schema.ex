defmodule Jido.Action.Schema do
  @moduledoc """
  Unified schema validation interface supporting both NimbleOptions and Zoi.

  This adapter provides a consistent API for:
  - Schema validation
  - Key introspection
  - Error formatting
  - JSON Schema generation (for AI tools)
  """

  @type t :: NimbleOptions.schema() | struct() | []

  @doc """
  Detects the type of schema.

  Returns `:nimble` for NimbleOptions keyword list schemas, `:zoi` for Zoi schemas,
  `:empty` for empty lists, or `:unknown` for unsupported types.
  """
  @spec schema_type(t()) :: :nimble | :zoi | :empty | :unknown
  def schema_type([]), do: :empty
  def schema_type(schema) when is_list(schema), do: :nimble

  def schema_type(schema) do
    if impl_for_zoi_type?(schema) do
      :zoi
    else
      :unknown
    end
  end

  @doc """
  Validates data against a schema.

  For NimbleOptions schemas, returns `{:ok, map()}` with validated data as a map.
  For Zoi schemas, returns `{:ok, struct()}` with the validated struct.
  For empty schemas, returns the data unchanged.

  ## Parameters
    * `schema` - NimbleOptions schema (keyword list) or Zoi schema
    * `data` - Data to validate (map or keyword list)

  ## Returns
    * `{:ok, validated_data}` - Validation succeeded
    * `{:error, error}` - Validation failed
  """
  @spec validate(t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def validate(schema, data) do
    case schema_type(schema) do
      :empty -> {:ok, data}
      :nimble -> validate_nimble(schema, data)
      :zoi -> validate_zoi(schema, data)
      :unknown -> {:error, "Unsupported schema type"}
    end
  end

  @doc """
  Extracts all known keys from a schema.

  ## Parameters
    * `schema` - NimbleOptions schema or Zoi schema

  ## Returns
    * List of atom keys defined in the schema
  """
  @spec known_keys(t()) :: [atom()]
  def known_keys([]), do: []
  def known_keys(schema) when is_list(schema), do: Keyword.keys(schema)
  def known_keys(schema), do: extract_zoi_keys(schema)

  @doc """
  Converts a schema to JSON Schema format for AI tools.

  For NimbleOptions schemas, converts to OpenAI-compatible JSON Schema.
  For Zoi schemas, uses Zoi's built-in JSON Schema conversion.

  ## Parameters
    * `schema` - NimbleOptions schema or Zoi schema

  ## Returns
    * Map representing the JSON Schema
  """
  @spec to_json_schema(t()) :: map()
  def to_json_schema([]), do: %{}
  def to_json_schema(schema) when is_list(schema), do: nimble_to_json_schema(schema)
  def to_json_schema(schema), do: Zoi.to_json_schema(schema)

  @doc """
  Formats validation errors into Jido.Action.Error structs.

  ## Parameters
    * `error` - The error from validation (NimbleOptions.ValidationError, Zoi.Error, or list)
    * `context` - Context string describing where the error occurred
    * `module` - The module where the error occurred

  ## Returns
    * `Jido.Action.Error.InvalidInputError.t()` - Formatted error struct
  """
  @spec format_error(term(), String.t(), module()) ::
          Jido.Action.Error.InvalidInputError.t()
  def format_error(error, context, module) do
    case error do
      %NimbleOptions.ValidationError{} = nimble_error ->
        nimble_error
        |> Jido.Action.Error.format_nimble_validation_error(context, module)
        |> Jido.Action.Error.validation_error()

      %Zoi.Error{} = zoi_error ->
        format_zoi_error(zoi_error, context, module)

      errors when is_list(errors) ->
        message = Zoi.prettify_errors(errors)

        Jido.Action.Error.validation_error(message, %{
          context: context,
          module: module,
          errors: format_zoi_error_list(errors)
        })

      _ ->
        Jido.Action.Error.validation_error("Validation failed", %{
          context: context,
          module: module
        })
    end
  end

  @doc """
  Validates a schema value for use in configuration.

  Used during compilation to ensure schema configuration is valid.

  ## Parameters
    * `value` - The schema value to validate
    * `_opts` - Options (unused, for Zoi refine compatibility)

  ## Returns
    * `:ok` - Schema is valid
    * `{:error, message}` - Schema is invalid
  """
  @spec validate_config_schema(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_config_schema(value, _opts \\ [])

  def validate_config_schema(value, _opts) when is_list(value), do: :ok

  def validate_config_schema(value, _opts) do
    if impl_for_zoi_type?(value) do
      :ok
    else
      {:error, "must be NimbleOptions schema or Zoi schema"}
    end
  end

  # Private Functions

  defp impl_for_zoi_type?(value) do
    is_struct(value) && Zoi.Type.impl_for(value) != nil
  rescue
    _ -> false
  end

  defp validate_nimble(schema, data) do
    data_kw = if is_map(data), do: Enum.to_list(data), else: data

    case NimbleOptions.validate(data_kw, schema) do
      {:ok, validated_kw} -> {:ok, Map.new(validated_kw)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_zoi(schema, data) do
    case Zoi.parse(schema, data) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, errors}
    end
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Object, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Object, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp extract_zoi_keys(_), do: []

  defp nimble_to_json_schema(nimble_schema) do
    properties =
      Enum.reduce(nimble_schema, %{}, fn {key, opts}, acc ->
        type_info = nimble_type_to_json(opts[:type])
        description = opts[:doc] || opts[:description] || "No description provided."

        field_schema =
          type_info
          |> maybe_add_description(description)
          |> maybe_add_enum(opts[:keys])

        Map.put(acc, to_string(key), field_schema)
      end)

    required =
      nimble_schema
      |> Enum.filter(fn {_key, opts} -> opts[:required] end)
      |> Enum.map(fn {key, _opts} -> to_string(key) end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end

  defp nimble_type_to_json(:string), do: %{"type" => "string"}
  defp nimble_type_to_json(:integer), do: %{"type" => "integer"}
  defp nimble_type_to_json(:number), do: %{"type" => "integer"}
  defp nimble_type_to_json(:boolean), do: %{"type" => "boolean"}
  defp nimble_type_to_json(:float), do: %{"type" => "number"}
  defp nimble_type_to_json({:list, _}), do: %{"type" => "array"}
  defp nimble_type_to_json(:keyword_list), do: %{"type" => "object"}
  defp nimble_type_to_json(:map), do: %{"type" => "object"}
  defp nimble_type_to_json({:map, _}), do: %{"type" => "object"}
  defp nimble_type_to_json(_), do: %{"type" => "string"}

  defp maybe_add_description(schema, nil), do: schema
  defp maybe_add_description(schema, desc), do: Map.put(schema, "description", desc)

  defp maybe_add_enum(schema, nil), do: schema

  defp maybe_add_enum(schema, keys) when is_list(keys) do
    Map.put(schema, "enum", Enum.map(keys, &to_string/1))
  end

  defp format_zoi_error(error, context, module) do
    Jido.Action.Error.validation_error(error.message, %{
      context: context,
      module: module,
      path: error.path,
      code: error.code
    })
  end

  defp format_zoi_error_list(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{path: path, message: message} = error ->
        %{
          path: path,
          message: message,
          code: Map.get(error, :code)
        }

      error ->
        %{message: inspect(error)}
    end)
  end
end
