defmodule Jido.Action.Schema do
  @moduledoc """
  Zoi-backed schema validation interface for actions.

  This adapter provides a consistent API for:
  - Schema validation
  - Key introspection
  - Error formatting
  """

  @type t :: struct() | []

  @doc """
  Detects the type of schema.

  Returns `:zoi` for Zoi schemas, `:empty` for empty lists, or `:unknown`
  for unsupported types.
  """
  @spec schema_type(term()) :: :zoi | :empty | :unknown
  def schema_type([]), do: :empty

  def schema_type(schema) do
    if impl_for_zoi_type?(schema) do
      :zoi
    else
      :unknown
    end
  end

  @doc """
  Validates data against a schema.

  For Zoi schemas, returns `{:ok, map()}` with the validated data.
  For empty schemas, returns the data unchanged.

  ## Parameters
    * `schema` - Zoi schema or empty list
    * `data` - Data to validate (map or keyword list)

  ## Returns
    * `{:ok, validated_data}` - Validation succeeded
    * `{:error, error}` - Validation failed
  """
  @spec validate(t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def validate(schema, data) do
    case schema_type(schema) do
      :empty -> {:ok, data}
      :zoi -> validate_zoi(schema, data)
      :unknown -> {:error, "Unsupported schema type"}
    end
  end

  @doc """
  Extracts all known keys from a schema.

  ## Parameters
    * `schema` - Zoi schema or empty list

  ## Returns
    * List of atom keys defined in the schema
  """
  @spec known_keys(term()) :: [atom()]
  def known_keys([]), do: []

  def known_keys(schema), do: extract_zoi_keys(schema)

  @doc """
  Formats validation errors into Jido.Action.Error structs.

  ## Parameters
    * `error` - The error from validation (Zoi.Error or list)
    * `context` - Context string describing where the error occurred
    * `module` - The module where the error occurred

  ## Returns
    * `Jido.Action.Error.InvalidInputError.t()` - Formatted error struct
  """
  @spec format_error(term(), String.t(), module()) ::
          Jido.Action.Error.InvalidInputError.t()
  def format_error(error, context, module) do
    case error do
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

  def validate_config_schema([], _opts), do: :ok

  def validate_config_schema(value, _opts) do
    if impl_for_zoi_type?(value) do
      :ok
    else
      {:error, "must be a Zoi schema"}
    end
  end

  # Private Functions

  defp impl_for_zoi_type?(value) do
    is_struct(value) && Zoi.Type.impl_for(value) != nil
  rescue
    _ -> false
  end

  defp validate_zoi(schema, data) do
    Zoi.parse(schema, data)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_map(fields) do
    Map.keys(fields)
  end

  defp extract_zoi_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp extract_zoi_keys(_), do: []

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
